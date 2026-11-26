"""Честная проверка подсказки при «не понял» (ADR-046, п. 2 и 6).

Пробы и метрики — те же, что у «Лёгкой» (ADR-045): fresh, held2, held3 из
`tools/intent_model/eval`, `knn.at_threshold`, бюджет ошибок `config.py`
модели понимания. Модель не обучается на корпусе и не видит его фраз,
поэтому снимки корпуса не нужны: проба честная как есть. Порог — на fresh
(наибольший catch в бюджете), проверка — held2 + held3.

Прогоняются только фразы, по которым считаются метрики: которых правила не
поняли (catch, wrong), и «не команды» (ложные тревоги).
"""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

from tools.intent_model import config as intent_config
from tools.intent_model import data, knn

from . import config
from .prompt import NONE


def probes() -> dict[str, list[dict]]:
    out = {}
    for name in intent_config.EVAL_SETS:
        rows = data.load_eval(name)
        out[name] = [r for r in rows if r.get("rule_outcome") == "none" or r["label"] == "none"]
    return out


def labels() -> dict[str, str]:
    """Описания всех меток, которые встречаются в корпусе и пробах."""
    return data.load_descriptions()


def examples(set_name: str, per_label: int) -> dict[str, list[str]]:
    """По `per_label` фраз на метку из снимка корпуса до разбора пробы.

    Фразы снимка, похожие на фразы пробы, убирает `data.prepare` (тем же
    правилом, что у «Лёгкой»). Выбор детерминирован: по sha1 текста.
    """
    snap = data.snapshots()[set_name]["commit"]
    texts = [r["text"] for r in data.load_eval(set_name)]
    rows, _ = data.prepare(data.train_files((), snap), texts)
    by: dict[str, list[str]] = {}
    for r in sorted(rows, key=lambda r: hashlib.sha1(r["text"].encode("utf-8")).hexdigest()):
        if len(by.setdefault(r["label"], [])) < per_label:
            by[r["label"]].append(r["text"])
    return by


def pick_threshold(evals: list[dict], preds: list[dict]) -> float | None:
    return knn.pick_threshold(evals, preds, grid=config.GRID)


def report(per_set: dict[str, tuple[list[dict], list[dict]]], t: float) -> dict:
    def merged(names):
        ev, pr = [], []
        for n in names:
            ev += per_set[n][0]
            pr += per_set[n][1]
        return ev, pr

    out = {"threshold": t}
    for key, names in (("dev", [intent_config.DEV_SET]), ("test", ["held2", "held3"]), ("all", list(per_set))):
        m = knn.at_threshold(*merged(names), t)
        m["within_budget"] = knn.within_budget(m)
        out[key] = m
    return out


def run(chooser, name: str, out_dir: Path, prepare=None, tag: str = "intent") -> dict:
    """`chooser(text) -> (label, conf)`; `prepare(set_name)` — перед каждой
    пробой. Результат — `out_dir/<tag>.json`."""
    per_set: dict[str, tuple[list[dict], list[dict]]] = {}
    rows_out = []
    times = []
    for set_name, rows in probes().items():
        if prepare is not None:
            prepare(set_name)
        preds = []
        for r in rows:
            started = time.perf_counter()
            label, conf = chooser(r["text"])
            times.append(time.perf_counter() - started)
            preds.append({"pred": label, "sim": conf, "second": None})
            rows_out.append({"set": set_name, "id": r["id"], "label": r["label"], "pred": label, "conf": round(conf, 4)})
        per_set[set_name] = (rows, preds)
    dev_ev, dev_pr = per_set[intent_config.DEV_SET]
    t = pick_threshold(dev_ev, dev_pr)
    result = {
        "model": name,
        "phrases": len(rows_out),
        "seconds_per_phrase": {
            "median": round(sorted(times)[len(times) // 2], 3),
            "p90": round(sorted(times)[int(len(times) * 0.9)], 3),
        },
        "budget": {
            "max_wrong_of_suggested": intent_config.MAX_WRONG_OF_SUGGESTED,
            "max_false_alarm": intent_config.MAX_FALSE_ALARM,
        },
        "honest": report(per_set, t) if t is not None else None,
        # Без порога (подсказка всегда, кроме none): потолок модели.
        "no_threshold": report(per_set, 0.0),
        "none_label": NONE,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{tag}.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    data.write_jsonl(out_dir / f"{tag}_preds.jsonl", rows_out)
    return result
