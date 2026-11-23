"""Проверка квантования: сходство векторов фразы, закодированной одной
(bs=1, без паддинга — как на устройстве) и в пакете по 32 (bs=32, как по
умолчанию в сборке), и разница метрик kNN при такой замене. Нужна готовая
модель уровня (`model --tier <уровень>`). Пишет `out/<уровень>/bs_compare.json`.

    python -m tools.intent_model.bs_compare <уровень>
"""

from __future__ import annotations

import json
import sys

import numpy as np

from . import config, data, knn
from .model import Int8Encoder, log


def _cos_rows(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    a, b = a.astype(np.float64), b.astype(np.float64)
    return (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1))


def _eval_at_threshold(idx: np.ndarray, labels: list[str], probes: dict[str, np.ndarray], evals: dict[str, list[dict]]) -> dict:
    per_set = {name: (evals[name], knn.knn(idx, labels, probes[name])) for name in probes}
    dev = per_set[config.DEV_SET]
    t = knn.pick_threshold(*dev)
    if t is None:
        return {"threshold": None}
    names = list(per_set)
    merged = [e for n in names for e in per_set[n][0]], [p for n in names for p in per_set[n][1]]
    held = [n for n in names if n != config.DEV_SET]
    merged_held = [e for n in held for e in per_set[n][0]], [p for n in held for p in per_set[n][1]]
    return {"threshold": t, "all": knn.at_threshold(*merged, t), "held": knn.at_threshold(*merged_held, t)}


def run(tier_name: str) -> dict:
    tier = config.tier(tier_name)
    md = config.tier_dir(tier.source) / "model"
    rows = data.read_jsonl(md / "train.jsonl")
    train_texts = [r["text"] for r in rows]
    labels = [data.restrict(r["label"], tier.connectors) for r in rows]
    enc = Int8Encoder(md, prefix=tier.prefix)

    idx32 = enc.encode(train_texts, bs=32)
    idx1 = enc.encode(train_texts, bs=1)
    c_idx = _cos_rows(idx32, idx1)
    log(f"[{tier_name}] индекс {len(train_texts)} фраз: косинус bs=1 vs bs=32 — "
        f"min {c_idx.min():.4f}, медиана {np.median(c_idx):.4f}")

    out = {
        "tier": tier_name,
        "index_cosine_bs1_vs_bs32": {"min": round(float(c_idx.min()), 6), "median": round(float(np.median(c_idx)), 6)},
    }
    evals, p32, p1, cos = {}, {}, {}, {}
    for name in config.EVAL_SETS:
        evals[name] = data.load_eval(name, tier.connectors)
        texts = [e["text"] for e in evals[name]]
        p32[name] = enc.encode(texts, bs=32)
        p1[name] = enc.encode(texts, bs=1)
        c = _cos_rows(p32[name], p1[name])
        cos[name] = {"min": round(float(c.min()), 6), "median": round(float(np.median(c)), 6)}
        log(f"[{tier_name}] проба {name} {len(texts)} фраз: косинус bs=1 vs bs=32 — "
            f"min {c.min():.4f}, медиана {np.median(c):.4f}")
    out["probe_cosine_bs1_vs_bs32"] = cos

    combos = {
        "both32": _eval_at_threshold(idx32, labels, p32, evals),
        "device_like": _eval_at_threshold(idx32, labels, p1, evals),
        "both1": _eval_at_threshold(idx1, labels, p1, evals),
    }
    out["combos"] = combos
    for name, r in combos.items():
        if r["threshold"] is None:
            log(f"[{tier_name}] {name}: порог в бюджете не найден")
            continue
        a = r["all"]
        log(f"[{tier_name}] {name}: порог {r['threshold']}, catch {a['catch']} %, "
            f"неверных из подсказок {a['wrong_of_suggested']} %, ложные тревоги {a['false_alarm']} %")

    path = config.tier_dir(tier_name) / "bs_compare.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"[{tier_name}] -> {path}")
    return out


if __name__ == "__main__":
    run(sys.argv[1])
