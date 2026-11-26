"""Согласие слоёв: подсказка Qwen, только если «Лёгкая» с ней согласна.

Векторы «Лёгкой» — честные пробы `tools/intent_model` (шаг `holdout`
уровня accurate: модель на снимке корпуса до разбора каждой пробы,
`out/accurate/calib/<проба>.npz`). Метки kNN ранжируются голосом k = 5
ближайших (как `knn.knn`). Варианты:

- `light` — только «Лёгкая» (как ADR-045, для сравнения);
- `agree@m` — метка Qwen не `none` и среди m первых меток kNN; порог — по
  сходству лучшего примера этой метки у «Лёгкой».

Порог — на fresh, проверка — held2 + held3, бюджет — ADR-045.
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

import numpy as np

from tools.intent_model import config as intent_config
from tools.intent_model import data, knn

from . import config, intent_eval

GRID = [round(0.70 + 0.005 * i, 3) for i in range(57)]


def ranked(train: np.ndarray, labels, queries: np.ndarray, k: int = intent_config.K) -> list[list[tuple[str, float]]]:
    sims = queries.astype(np.float32) @ train.astype(np.float32).T
    top = np.argsort(-sims, axis=1, kind="stable")[:, :k]
    out = []
    for i in range(queries.shape[0]):
        votes: dict = defaultdict(float)
        best: dict = defaultdict(lambda: -1.0)
        for j in top[i]:
            s = float(sims[i, j])
            votes[labels[j]] += max(s, 0.0)
            best[labels[j]] = max(best[labels[j]], s)
        order = sorted(votes.items(), key=lambda x: (-x[1], x[0]))
        out.append([(lab, best[lab]) for lab, _ in order])
    return out


def load_light(calib: Path) -> dict[str, dict[str, list[tuple[str, float]]]]:
    out = {}
    for name in intent_config.EVAL_SETS:
        z = np.load(calib / f"{name}.npz")
        r = ranked(z["train"], [str(x) for x in z["labels"]], z["eval"])
        out[name] = dict(zip([str(x) for x in z["eval_ids"]], r))
    return out


def combine(rank: list[tuple[str, float]], gen: str, m: int | None) -> dict:
    if m is None:
        lab, sim = rank[0]
        return {"pred": lab, "sim": sim, "second": None}
    labels = [lab for lab, _ in rank[:m]]
    if gen != "none" and gen in labels:
        return {"pred": gen, "sim": dict(rank)[gen], "second": None}
    return {"pred": "none", "sim": 0.0, "second": None}


def run(gen_preds: Path, calib: Path, out: Path) -> dict:
    light = load_light(calib)
    gen = {(r["set"], r["id"]): r["pred"] for r in data.read_jsonl(gen_preds)}
    sets = intent_eval.probes()
    result = {"gen_preds": str(gen_preds.relative_to(config.REPO)) if gen_preds.is_relative_to(config.REPO) else str(gen_preds)}
    for name, m in (("light", None), ("agree@1", 1), ("agree@2", 2), ("agree@3", 3)):
        per_set = {}
        for s, rows in sets.items():
            preds = [combine(light[s][r["id"]], gen[(s, r["id"])], m) for r in rows]
            per_set[s] = (rows, preds)
        t = knn.pick_threshold(*per_set[intent_config.DEV_SET], grid=GRID)
        result[name] = intent_eval.report(per_set, t) if t is not None else None
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    return result
