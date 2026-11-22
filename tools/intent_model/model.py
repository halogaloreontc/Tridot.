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


def train(tier: config.Tier, rows: Sequence[dict], threads: int | None = None):
    """Дообученная SentenceTransformer (в памяти, на диск не пишется)."""
    import torch
    from sentence_transformers import SentenceTransformer

    torch.manual_seed(config.SEED)
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
    for step, idx in enumerate(batches(rows, steps)):
        feats = model.tokenize([tier.prefix + rows[i]["text"] for i in idx])
        z = torch.nn.functional.normalize(model(feats)["sentence_embedding"], dim=-1)
        loss = _supcon(z, torch.tensor([lab_id[rows[i]["label"]] for i in idx]), config.TAU)
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


def export(model, out_dir: Path, per_channel: bool) -> dict:
    """ONNX (кодировщик + пулинг + нормировка) → динамический int8.

    В out_dir остаются model.int8.onnx и файлы токенизатора; fp32 удаляется.
    """
    import torch
    from onnxruntime.quantization import QuantType, quantize_dynamic

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

    fp32 = out_dir / "model.fp32.onnx"
    int8 = out_dir / "model.int8.onnx"
    dyn = {n: {0: "batch", 1: "seq"} for n in names}
    dyn["embedding"] = {0: "batch"}
    with torch.no_grad():
        torch.onnx.export(
            Wrap(model), tuple(enc[n] for n in names), str(fp32), input_names=names,
            output_names=["embedding"], dynamic_axes=dyn, opset_version=17, dynamo=False,
        )
    quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QInt8, per_channel=per_channel)
    for f in list(out_dir.iterdir()):
        if f.name != int8.name and (f.suffix in (".onnx", ".data") or f.name.endswith(".onnx.data")):
            f.unlink()
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
        "quantization": "dynamic int8 (MatMulInteger), " + ("по каналам" if per_channel else "по тензору"),
    }
    (out_dir / "model_info.json").write_text(json.dumps(info, ensure_ascii=False, indent=1), encoding="utf-8")
    return info


class Int8Encoder:
    """Кодирование фраз выгруженной моделью: токенизатор только из tokenizer.json
    (как будет на устройстве), onnxruntime на CPU."""

    def __init__(self, model_dir: Path, threads: int = 0, prefix: str = "", info_dir: Path | None = None,
                 wasm: bool = False):
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
        self.model_path = model_dir / "model.int8.onnx"
        self.sess = ort.InferenceSession(str(self.model_path), so, providers=["CPUExecutionProvider"])
        # encode() — в onnxruntime-web (node, webcheck/encode.mjs), как в браузере.
        self.wasm = wasm

    def feeds(self, texts: Sequence[str]) -> dict:
        enc = self.tok.encode_batch([self.prefix + t for t in texts])
        f = {
            "input_ids": np.array([e.ids for e in enc], dtype=np.int64),
            "attention_mask": np.array([e.attention_mask for e in enc], dtype=np.int64),
            "token_type_ids": np.array([e.type_ids for e in enc], dtype=np.int64),
        }
        return {n: f[n] for n in self.names}

    def encode(self, texts: Sequence[str], bs: int = 32) -> np.ndarray:
        if self.wasm:
            return self.encode_wasm(texts)
        out = [self.sess.run(None, self.feeds(texts[i : i + bs]))[0] for i in range(0, len(texts), bs)]
        return np.concatenate(out).astype(np.float32) if out else np.zeros((0, 1), np.float32)

    def encode_wasm(self, texts: Sequence[str], procs: int = 0) -> np.ndarray:
        """Векторы onnxruntime-web (WASM) через node — по одной фразе без
        дополнения, как в браузере: у int8 с динамическим квантованием
        соседи по пакету и дополнение сдвигают вектор (у USER-base косинус
        с пакетом 32 — ~0,92). Несколько процессов node параллельно."""
        import subprocess
        import tempfile

        script = config.PKG / "webcheck" / "encode.mjs"
        if not (config.PKG / "webcheck" / "node_modules" / "onnxruntime-web").exists():
            raise SystemExit(f"Нет onnxruntime-web: cd {script.parent} && npm ci")
        if not texts:
            return np.zeros((0, 1), np.float32)
        procs = procs or max(1, min(4, os.cpu_count() or 1))
        parts = [list(range(len(texts)))[i::procs] for i in range(procs)]
        parts = [p for p in parts if p]
        out = np.zeros((len(texts), 0), np.float32)
        with tempfile.TemporaryDirectory() as tmp:
            runs = []
            for n, part in enumerate(parts):
                batches = []
                for i in part:
                    f = self.feeds([texts[i]])
                    batches.append({"inputs": {k: v.tolist() for k, v in f.items()}, "dims": list(f["input_ids"].shape)})
                fin, fout = Path(tmp) / f"in{n}.json", Path(tmp) / f"out{n}.json"
                fin.write_text(json.dumps(batches))
                runs.append((part, fout, subprocess.Popen(
                    ["node", str(script), str(self.model_path), str(fin), str(fout)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)))
            for part, fout, proc in runs:
                _, err = proc.communicate()
                if proc.returncode != 0:
                    raise SystemExit(f"onnxruntime-web не посчитал векторы:\n{err[-3000:]}")
                got = json.loads(fout.read_text())
                arr = np.array(got["data"], dtype=np.float32).reshape(got["dims"])
                if out.shape[1] == 0:
                    out = np.zeros((len(texts), arr.shape[1]), np.float32)
                out[part] = arr
        return out / np.maximum(np.linalg.norm(out, axis=1, keepdims=True), 1e-12)

    def latency_ms(self, texts: Sequence[str]) -> dict:
        for x in texts[:20]:
            self.encode([x])
        ms = []
        for x in texts:
            t0 = time.perf_counter()
            self.encode([x])
            ms.append(1000 * (time.perf_counter() - t0))
        return {"median": round(float(np.median(ms)), 2), "p95": round(float(np.percentile(ms, 95)), 2)}
