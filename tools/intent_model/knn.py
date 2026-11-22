"""kNN по примерам и метрики запасного слоя (только numpy).

Подсказка — когда победила не `none` и сходство лучшего примера
победившей метки не ниже порога. Метрики:

- catch — доля фраз, которых правила не поняли (rule_outcome = none),
  где подсказка верна (метка или допустимая alt); catch_of_commands — то же
  среди таких фраз с командой этого уровня (без «не команда»);
- wrong — доля таких фраз с неверной подсказкой;
- wrong_of_suggested — неверных среди всех подсказок (бюджет ~6 %);
- false_alarm — доля фраз «не команда» (метка none), где подсказка есть.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Sequence

import numpy as np

from . import config


def knn(train: np.ndarray, labels: Sequence[str], queries: np.ndarray, k: int = config.K) -> list[dict]:
    """Голосование k ближайших (косинус, векторы нормированы), вес — сходство."""
    train = np.asarray(train, dtype=np.float32)
    queries = np.asarray(queries, dtype=np.float32)
    sims = queries @ train.T
    k = min(k, train.shape[0])
    top = np.argsort(-sims, axis=1, kind="stable")[:, :k]
    out = []
    for i in range(queries.shape[0]):
        votes: dict = defaultdict(float)
        best: dict = defaultdict(lambda: -1.0)
        for j in top[i]:
            s = float(sims[i, j])
            lab = labels[j]
            votes[lab] += max(s, 0.0)
            best[lab] = max(best[lab], s)
        ranked = sorted(votes.items(), key=lambda x: (-x[1], x[0]))
        out.append(
            {
                "pred": ranked[0][0],
                "sim": best[ranked[0][0]],
                "second": ranked[1][0] if len(ranked) > 1 else None,
            }
        )
    return out


def suggests(p: dict, t: float) -> bool:
    return p["pred"] != "none" and p["sim"] >= t


def is_ok(e: dict, pred: str) -> bool:
    return pred == e["label"] or pred in e.get("alt", [])


def at_threshold(evals: Sequence[dict], preds: Sequence[dict], t: float) -> dict:
    rn = [i for i, e in enumerate(evals) if e.get("rule_outcome") == "none"]
    gn = [i for i, e in enumerate(evals) if e["label"] == "none"]
    c = w = 0
    for i in rn:
        if suggests(preds[i], t):
            if is_ok(evals[i], preds[i]["pred"]):
                c += 1
            else:
                w += 1
    fa = sum(1 for i in gn if suggests(preds[i], t) and not is_ok(evals[i], preds[i]["pred"]))
    n = len(rn)
    # Фразы, у которых есть команда этого уровня: столько можно поймать.
    known = sum(1 for i in rn if evals[i]["label"] != "none")
    return {
        "rules_not_understood": n,
        "catch": round(100 * c / n, 1) if n else 0.0,
        "catch_of_commands": round(100 * c / known, 1) if known else 0.0,
        "wrong": round(100 * w / n, 1) if n else 0.0,
        "wrong_of_suggested": round(100 * w / (c + w), 1) if c + w else 0.0,
        "suggested": c + w,
        "none_phrases": len(gn),
        "false_alarm": round(100 * fa / len(gn), 1) if gn else 0.0,
        "top1": round(100 * sum(is_ok(e, p["pred"]) for e, p in zip(evals, preds)) / max(1, len(evals)), 1),
    }


def within_budget(m: dict) -> bool:
    return m["wrong_of_suggested"] <= config.MAX_WRONG_OF_SUGGESTED and m["false_alarm"] <= config.MAX_FALSE_ALARM


def pick_threshold(
    evals: Sequence[dict],
    preds: Sequence[dict],
    grid: Sequence[float] = config.GRID,
    each: Sequence[tuple[Sequence[dict], Sequence[dict]]] = (),
) -> float | None:
    """Порог с наибольшим catch в пределах бюджета; при равенстве — выше.

    each — пробы, которые и по отдельности должны уложиться в бюджет (у
    веб-уровней — половина cal складской: в общей куче её ложные тревоги
    тонут среди ~800 фраз «не команда» общих проб).
    """
    best = None
    for t in grid:
        m = at_threshold(evals, preds, t)
        if m["catch"] > 0 and within_budget(m) and all(within_budget(at_threshold(e, p, t)) for e, p in each):
            if best is None or m["catch"] >= best[1]:
                best = (t, m["catch"])
    return best[0] if best else None
