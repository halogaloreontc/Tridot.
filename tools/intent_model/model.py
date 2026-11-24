"""Дообучение (SupCon), выгрузка в ONNX с int8 и кодирование фраз моделью int8.

torch, sentence-transformers и onnxruntime импортируются внутри функций:
подготовка данных, упаковка и их тесты работают без них.
"""

from __future__ import annotations

import json
import math
import os
import random
import shutil
import time
from pathlib import Path
from typing import Sequence

import numpy as np

from . import config

# Файлы токенизатора, которые уходят в пакет (что есть у модели).
TOKENIZER_FILES = (
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "vocab.txt",
    "vocab.json",
    "merges.txt",
)
HF_IGNORE = ["onnx/*", "openvino/*", "pytorch_model.bin", "*.h5", "*.msgpack", "*.ot", "tf_model*", "flax*", "rust*", "*.pt"]


def log(msg: str) -> None:
    print(msg, flush=True)


def base_path(tier: config.Tier) -> str:
    from huggingface_hub import snapshot_download

    return snapshot_download(tier.base_model, revision=tier.revision, ignore_patterns=HF_IGNORE)


def _supcon(z, labels, tau: float):
    import torch

    sim = z @ z.T / tau
    eye = torch.eye(z.shape[0], dtype=torch.bool)
    sim = sim.masked_fill(eye, -1e9)
    logp = sim - torch.logsumexp(sim, dim=1, keepdim=True)
    pos = (labels[:, None] == labels[None, :]) & ~eye
    cnt = pos.sum(1)
    ok = cnt > 0
    return (-(logp * pos).sum(1)[ok] / cnt[ok]).mean()


def batches(rows: Sequence[dict], steps: int, seed: int = config.SEED):
    """Пакеты P меток × K фраз; метки — с весом √(число фраз)."""
    rng = random.Random(seed)
    by: dict = {}
    for i, r in enumerate(rows):
        by.setdefault(r["label"], []).append(i)
    labs = sorted(lab for lab, ix in by.items() if len(ix) >= 2)
    w = [math.sqrt(len(by[lab])) for lab in labs]
    p = min(config.BATCH_LABELS, len(labs))
    for _ in range(steps):
        chosen: set = set()
        while len(chosen) < p:
            chosen.add(rng.choices(labs, weights=w)[0])
        idx: list = []
        for lab in sorted(chosen):
            pool = by[lab]
            idx += rng.sample(pool, min(config.BATCH_PER_LABEL, len(pool)))
        yield idx


def train(tier: config.Tier, rows: Sequence[dict], threads: int | None = None, seed: int = config.SEED):
    """Дообученная SentenceTransformer (в памяти, на диск не пишется)."""
    import torch
    from sentence_transformers import SentenceTransformer

    torch.manual_seed(seed)
    torch.set_num_threads(threads or max(1, os.cpu_count() or 1))
    model = SentenceTransformer(base_path(tier), device="cpu")
    model.max_seq_length = config.MAX_LEN
    lab_id = {lab: i for i, lab in enumerate(sorted({r["label"] for r in rows}))}
    per_batch = config.BATCH_LABELS * config.BATCH_PER_LABEL
    steps = int(tier.epochs * len(rows) / per_batch)
    opt = torch.optim.AdamW(model.parameters(), lr=tier.lr, weight_decay=0.01)
    warm = max(1, steps // 10)

    def lr_at(s: int) -> float:
        if s < warm:
            return (s + 1) / warm
        return max(0.0, (steps - s) / max(1, steps - warm))

    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_at)
    model.train()
    t0 = time.time()
    for step, idx in enumerate(batches(rows, steps, seed=seed)):
        feats = model.tokenize([tier.prefix + rows[i]["text"] for i in idx])
        z = torch.nn.functional.normalize(model(feats)["sentence_embedding"], dim=-1)
        loss = _supcon(z, torch.tensor([lab_id[rows[i]["label"]] for i in idx]), config.TAU)
        if not torch.isfinite(loss):
            raise SystemExit(f"обучение разошлось: loss не конечен на шаге {step} (seed {seed})")
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        sched.step()
        opt.zero_grad()
        if step % 25 == 0:
            log(f"  шаг {step}/{steps} loss {loss.item():.3f} {time.time() - t0:.0f} с")
    model.eval()
    log(f"  обучение: {steps} шагов, {time.time() - t0:.0f} с")
    return model, {"steps": steps, "train_sec": round(time.time() - t0), "rows": len(rows)}


def degenerate(emb: np.ndarray, limit: float = 0.95) -> bool:
    """Схлопнувшаяся модель: почти все векторы фраз почти одинаковы.

    Обучение SupCon на CPU недетерминированно (параллельные редукции), и
    изредка сходится в вырожденную точку: средний косинус между разными
    фразами ~0.97+ против ~0.6 у здоровой модели, kNN подсказывает одну и
    ту же метку на всём подряд (измерено на прогоне 2026-11-24). Такая
    модель всё равно не пройдёт бюджет ошибок в verify — лучше узнать сразу
    и переобучить с другим seed (holdout/build_model это делают сами).
    """
    v = np.asarray(emb, dtype=np.float32)
    v = v / np.linalg.norm(v, axis=1, keepdims=True)
    s = v @ v.T
    off = s[~np.eye(len(v), dtype=bool)]
    return bool(off.mean() > limit)


def pooling_of(model) -> str:
    """Пулинг модели: cls, mean, max … (порт на Dart должен повторить его)."""
    for m in model:
        if type(m).__name__ != "Pooling":
            continue
        d = m.get_config_dict()
        if d.get("pooling_mode"):
            return str(d["pooling_mode"])
        for mode in ("cls_token", "mean_tokens", "max_tokens", "lasttoken"):
            if d.get(f"pooling_mode_{mode}"):
                return mode.split("_")[0]
    return "unknown"


def _export_fp32(model, out_dir: Path) -> dict:
    """fp32 ONNX (кодировщик + пулинг + нормировка), токенизатор, model_info."""
    import torch

    out_dir.mkdir(parents=True, exist_ok=True)
    tok = model.tokenizer
    enc = tok(["пример фразы"], return_tensors="pt")
    use_tt = "token_type_ids" in enc
    names = ["input_ids", "attention_mask"] + (["token_type_ids"] if use_tt else [])

    class Wrap(torch.nn.Module):
        def __init__(self, st):
            super().__init__()
            self.st = st

        def forward(self, input_ids, attention_mask, token_type_ids=None):
            f = {"input_ids": input_ids, "attention_mask": attention_mask}
            if use_tt:
                f["token_type_ids"] = token_type_ids
            return torch.nn.functional.normalize(self.st(f)["sentence_embedding"], dim=-1)

    dyn = {n: {0: "batch", 1: "seq"} for n in names}
    dyn["embedding"] = {0: "batch"}
    with torch.no_grad():
        torch.onnx.export(
            Wrap(model), tuple(enc[n] for n in names), str(out_dir / "model.fp32.onnx"),
            input_names=names, output_names=["embedding"], dynamic_axes=dyn,
            opset_version=17, dynamo=False,
        )
    tmp = out_dir / "_tok"
    tok.save_pretrained(str(tmp))
    for f in TOKENIZER_FILES:
        if (tmp / f).exists():
            shutil.copy(tmp / f, out_dir / f)
    shutil.rmtree(tmp)
    info = {
        "inputs": names,
        "output": "embedding",
        "dims": int(getattr(model, "get_embedding_dimension", None) and model.get_embedding_dimension() or model.get_sentence_embedding_dimension()),
        "pooling": pooling_of(model),
        "normalized": True,
        "max_length": config.MAX_LEN,
        "opset": 17,
    }
    (out_dir / "model_info.json").write_text(json.dumps(info, ensure_ascii=False, indent=1), encoding="utf-8")
    return info


def embeddings_fp32(model, texts: Sequence[str], prefix: str = "") -> np.ndarray:
    """Векторы fp32 модели (torch) по одной фразе — эталон для проверки int8."""
    import torch

    out = []
    with torch.no_grad():
        for t in texts:
            f = model.tokenize([prefix + t])
            z = torch.nn.functional.normalize(model(f)["sentence_embedding"], dim=-1)
            out.append(z[0].numpy())
    return np.array(out, dtype=np.float32)


def _cosines(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1))


def export(model, out_dir: Path, per_channel: bool) -> dict:
    """ONNX → динамический int8 (без проверки качества; см. export_checked).

    В out_dir остаются model.int8.onnx и файлы токенизатора; fp32 удаляется.
    """
    from onnxruntime.quantization import QuantType, quantize_dynamic

    info = _export_fp32(model, out_dir)
    fp32 = out_dir / "model.fp32.onnx"
    int8 = out_dir / "model.int8.onnx"
    quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QInt8, per_channel=per_channel)
    fp32.unlink()
    info["quantization"] = "dynamic int8 (MatMulInteger), " + ("по каналам" if per_channel else "по тензору")
    (out_dir / "model_info.json").write_text(json.dumps(info, ensure_ascii=False, indent=1), encoding="utf-8")
    return info


def export_checked(model, out_dir: Path, tier: config.Tier, probes: Sequence[str]) -> tuple[dict, np.ndarray]:
    """Экспорт int8 с проверкой векторов против fp32 на пробных фразах.

    Динамическое int8-квантование дообученной USER-base нестабильно: при
    нормально сошедшемся обучении (loss ~1.3) int8-модель иногда выдаёт почти
    одинаковые векторы на любые фразы (прогон 2026-11-24, accurate/fresh,
    held3, затем и held2 со всеми seed). Базовая модель без дообучения
    квантуется нормально — портит именно квантование дообученных весов.

    Поэтому: считаем эталон fp32 (torch), пробуем варианты квантования и
    берём первый, где int8 разумно совпадает с эталоном (средний косинус
    >= 0.7) и векторы не вырождены. Планка 0.7, а не выше: у здоровой
    USER-base динамический int8 даёт косинус с fp32 ~0.75-0.86 (замеры на
    базовой модели 2026-11-25), а вырожденная отсеивается флагом degenerate.
    Если fp32 сам вырожден — падаем сразу (надо переобучать, а не квантовать
    по-другому). Все замеры — в model_info.json.
    """
    from onnxruntime.quantization import QuantType, quantize_dynamic

    info = _export_fp32(model, out_dir)
    ref = embeddings_fp32(model, probes, tier.prefix)
    if degenerate(ref):
        raise SystemExit("fp32 модель схлопнулась (средний межфразовый косинус > 0.95) — нужно переобучение")
    fp32 = out_dir / "model.fp32.onnx"
    int8 = out_dir / "model.int8.onnx"
    tried = []

    def assess(name: str) -> bool:
        enc = Int8Encoder(out_dir, prefix=tier.prefix)
        ev8 = enc.encode(probes, bs=1)
        cos = _cosines(ev8, ref)
        q = {"variant": name, "mean_cos": round(float(cos.mean()), 4),
             "min_cos": round(float(cos.min()), 4), "degenerate": degenerate(ev8)}
        tried.append(q)
        log(f"  квантование {name}: косинус с fp32 mean {q['mean_cos']} min {q['min_cos']}, "
            f"вырождение {q['degenerate']}")
        return not q["degenerate"] and q["mean_cos"] >= 0.7

    def chosen(name: str) -> tuple[dict, np.ndarray]:
        info["quantization"] = name
        info["quantization_check"] = {"probes": len(probes), "tried": tried}
        (out_dir / "model_info.json").write_text(json.dumps(info, ensure_ascii=False, indent=1), encoding="utf-8")
        if fp32.exists():
            fp32.unlink()
        return info, ref

    variants = [
        (f"dynamic int8 (MatMulInteger), {'по каналам' if tier.per_channel else 'по тензору'}",
         dict(per_channel=tier.per_channel)),
        (f"dynamic int8 (MatMulInteger), {'по тензору' if tier.per_channel else 'по каналам'} (запасной вариант)",
         dict(per_channel=not tier.per_channel)),
        ("dynamic int8 (MatMulInteger), reduce_range", dict(per_channel=tier.per_channel, reduce_range=True)),
    ]
    for name, kw in variants:
        if int8.exists():
            int8.unlink()
        try:
            quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QInt8, **kw)
            if assess(name):
                return chosen(name)
        except Exception as e:  # сам вариант не сработал — пробуем следующий
            tried.append({"variant": name, "error": str(e)[-300:]})
            log(f"  квантование {name}: ошибка {str(e)[-200:]}")

    # Последний вариант: статическое квантование с калибровкой на пробах.
    name = "static int8 (QDQ), калибровка MinMax по пробным фразам"
    try:
        from onnxruntime.quantization import CalibrationDataReader, QuantFormat, quantize_static

        class _Reader(CalibrationDataReader):
            def __init__(self, feeds):
                self._it = iter(feeds)

            def get_next(self):
                return next(self._it, None)

        enc = Int8Encoder(out_dir, prefix=tier.prefix)
        feeds = [enc.feeds([t]) for t in probes]
        if int8.exists():
            int8.unlink()
        quantize_static(str(fp32), str(int8), _Reader(feeds), quant_format=QuantFormat.QDQ,
                        activation_type=QuantType.QUInt8, weight_type=QuantType.QInt8,
                        per_channel=tier.per_channel)
        if assess(name):
            return chosen(name)
    except Exception as e:
        tried.append({"variant": name, "error": str(e)[-300:]})
        log(f"  квантование {name}: ошибка {str(e)[-200:]}")
    raise SystemExit(f"ни один вариант квантования не сохранил векторы: {tried}")


class Int8Encoder:
    """Кодирование фраз выгруженной моделью: токенизатор только из tokenizer.json
    (как будет на устройстве), onnxruntime на CPU."""

    def __init__(self, model_dir: Path, threads: int = 0, prefix: str = "", info_dir: Path | None = None):
        import onnxruntime as ort
        from tokenizers import Tokenizer

        info = json.loads(((info_dir or model_dir) / "model_info.json").read_text(encoding="utf-8"))
        self.names = info["inputs"]
        self.prefix = prefix
        tok = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
        tok.enable_truncation(max_length=info["max_length"])
        pad_id = tok.token_to_id("[PAD]")
        if pad_id is None:
            pad_id = tok.token_to_id("<pad>") or 0
        tok.enable_padding(pad_id=pad_id)
        self.tok = tok
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads or max(1, os.cpu_count() or 1)
        so.inter_op_num_threads = 1
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self.sess = ort.InferenceSession(str(model_dir / "model.int8.onnx"), so, providers=["CPUExecutionProvider"])

    def feeds(self, texts: Sequence[str]) -> dict:
        enc = self.tok.encode_batch([self.prefix + t for t in texts])
        f = {
            "input_ids": np.array([e.ids for e in enc], dtype=np.int64),
            "attention_mask": np.array([e.attention_mask for e in enc], dtype=np.int64),
            "token_type_ids": np.array([e.type_ids for e in enc], dtype=np.int64),
        }
        return {n: f[n] for n in self.names}

    def encode(self, texts: Sequence[str], bs: int = 32) -> np.ndarray:
        out = [self.sess.run(None, self.feeds(texts[i : i + bs]))[0] for i in range(0, len(texts), bs)]
        return np.concatenate(out).astype(np.float32) if out else np.zeros((0, 1), np.float32)

    def latency_ms(self, texts: Sequence[str]) -> dict:
        for x in texts[:20]:
            self.encode([x])
        ms = []
        for x in texts:
            t0 = time.perf_counter()
            self.encode([x])
            ms.append(1000 * (time.perf_counter() - t0))
        return {"median": round(float(np.median(ms)), 2), "p95": round(float(np.percentile(ms, 95)), 2)}
