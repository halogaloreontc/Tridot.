"""Подготовка данных и метрики — без моделей и сети."""

import json
import re

import numpy as np
import pytest

from tools.intent_model import config, data, knn


def _lines(*rows):
    return [json.dumps(r, ensure_ascii=False) for r in rows]


def test_labels_and_skips():
    files = [
        (
            "x.jsonl",
            [
                "// комментарий",
                *_lines(
                    {"id": "a", "text": "Добавь задачу купить хлеб", "intent": "createTask"},
                    {"id": "b", "text": "добавь задачу купить хлеб!", "intent": "createTask"},  # дубль
                    {"id": "c", "text": "где лежит 64115", "connector": "warehouse", "intent": "warehouse.where"},
                    {"id": "d", "text": "привет мир", "intent": "unknown", "route": "none"},
                    {"id": "e", "text": "спасибо", "intent": "unknown", "route": "talk"},  # маршрут без команды
                    {"id": "f", "text": "в обед", "intent": "createTask", "status": "known_gap"},
                    {"id": "g", "text": "на завтра", "intent": "rescheduleTask", "after": "tasks"},
                    {"id": "h", "text": "покажи пароль от почты", "connector": "passwords", "intent": "passwords.reveal"},
                    {"id": "i", "text": "напомни сменить пароль", "intent": "createTask"},
                    {"id": "j", "text": "где записан пин от домофона", "connector": "warehouse", "intent": "warehouse.where"},
                ),
            ],
        )
    ]
    rows, stats = data.prepare(files)
    assert [(r["id"], r["label"]) for r in rows] == [
        ("a", "tasks:task.create"),
        ("c", "warehouse:warehouse.where"),
        ("d", "none"),
    ]
    assert stats["dup_in_corpus"] == 1
    assert stats["skip_unclear_route"] == 1
    assert stats["skip_known_gap"] == 1
    assert stats["skip_after_context"] == 1
    assert stats["skip_private_skill"] == 1
    assert stats["skip_private_text"] == 2


def test_leak_removed():
    files = [("x.jsonl", _lines({"id": "a", "text": "напомни завтра купить хлеба и молока", "intent": "createTask"},
                                {"id": "b", "text": "сколько будет два плюс два", "connector": "calc", "intent": "calc.evaluate"}))]
    rows, stats = data.prepare(files, ["Напомни завтра купить хлеба и молока, пожалуйста"])
    assert [r["id"] for r in rows] == ["b"]
    assert stats["removed_leak"] == 1


@pytest.mark.parametrize("text", ["какой пин от карты", "пароль от wifi", "мой логин", "код из смс", "PIN-код"])
def test_private(text):
    assert data.is_private(text)


@pytest.mark.parametrize("text", ["код ячейки 215", "кодовый замок", "Пинск", "пинцет на складе", "штрихкод"])
def test_not_private(text):
    assert not data.is_private(text)


def test_restrict_for_web():
    conns = config.WEB_CONNECTORS
    assert data.restrict("tasks:task.create", conns) == "none"
    assert data.restrict("warehouse:warehouse.where", conns) == "warehouse:warehouse.where"
    assert data.restrict("none", conns) == "none"
    assert data.restrict("tasks:task.create", ()) == "tasks:task.create"


def test_corpus_hash_order_free():
    a = [{"text": "x", "label": "none"}, {"text": "y", "label": "calc:calc.evaluate"}]
    assert data.corpus_hash(a) == data.corpus_hash(list(reversed(a)))


def test_every_corpus_label_has_description():
    rows, _ = data.prepare(data.corpus_files())
    data.check_descriptions([r["label"] for r in rows], data.load_descriptions())


def test_missing_description_fails():
    with pytest.raises(SystemExit, match="tasks:task.zzz"):
        data.check_descriptions(["tasks:task.zzz", "none"], {})


def test_eval_sets_and_snapshots():
    snaps = data.snapshots()
    for name in config.EVAL_SETS:
        rows = data.load_eval(name)
        assert rows and len(rows) <= snaps[name]["rows"]
        assert all(not data.is_private(r["text"]) for r in rows)
        assert {r["rule_outcome"] for r in rows} <= {"ok", "none", "slot", "misroute", "alt"}
    web = data.load_eval("fresh", config.WEB_CONNECTORS)
    assert {r["label"].split(":")[0] for r in web} <= {"none", *config.WEB_CONNECTORS}


def _unit(v):
    v = np.asarray(v, dtype=np.float32)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def test_knn_threshold_and_metrics():
    train = _unit([[1, 0, 0], [0.9, 0.1, 0], [0, 1, 0], [0, 0.9, 0.1], [0, 0, 1]])
    labels = ["a:x", "a:x", "b:y", "b:y", "none"]
    queries = _unit([[1, 0.05, 0], [0.05, 1, 0], [0, 0.1, 1], [0.6, 0.6, 0.5]])
    preds = knn.knn(train, labels, queries, k=2)
    assert [p["pred"] for p in preds[:3]] == ["a:x", "b:y", "none"]
    evals = [
        {"label": "a:x", "rule_outcome": "none"},
        {"label": "a:x", "rule_outcome": "none"},  # подсказка b:y — неверная
        {"label": "none", "rule_outcome": "ok"},
        {"label": "none", "rule_outcome": "ok"},
    ]
    m = knn.at_threshold(evals, preds, 0.5)
    assert m["catch"] == 50.0 and m["wrong"] == 50.0 and m["wrong_of_suggested"] == 50.0
    assert m["false_alarm"] == 50.0  # смешанная фраза — подсказка на «не команде»
    assert knn.pick_threshold(evals, preds, grid=[0.5]) is None


# --- складская проба и синтетика веб-уровня


def test_split_half_balanced_and_stable():
    ev = [{"id": f"w{i:02d}", "label": "a" if i % 3 else "none"} for i in range(30)]
    cal, test = data.split_half(ev)
    assert {e["id"] for e in cal} | {e["id"] for e in test} == {e["id"] for e in ev}
    assert not {e["id"] for e in cal} & {e["id"] for e in test}
    for lab in ("a", "none"):
        n_cal = sum(e["label"] == lab for e in cal)
        n_test = sum(e["label"] == lab for e in test)
        assert abs(n_cal - n_test) <= 1
    assert data.split_half(list(reversed(ev)))[0] == [e for e in reversed(ev) if e in cal]


def test_split_ignores_web_restriction():
    """Половины одинаковые для полного и урезанного набора меток."""
    full = data.load_eval(config.WEB_SET)
    web = data.load_eval(config.WEB_SET, config.WEB_CONNECTORS)
    assert [e["id"] for e in data.split_half(full)[1]] == [e["id"] for e in data.split_half(web)[1]]


def test_warehouse_eval_set():
    rows = data.load_eval(config.WEB_SET)
    assert len(rows) >= 240
    assert len({r["id"] for r in rows}) == len(rows)
    desc = data.load_descriptions()
    for r in rows:
        assert r["label"] == "none" or r["label"] in desc, r
        assert r["label"] == "none" or r["label"].split(":")[0] in config.WEB_CONNECTORS, r
        assert r["rule_outcome"] in {"ok", "alt", "slot", "none", "misroute"}, r
    assert sum(r["label"] == "none" for r in rows) >= 50
    assert config.WEB_SET in data.snapshots()
    cal, test = data.split_half(rows)
    assert abs(len(cal) - len(test)) <= len({r["label"] for r in rows})


def test_warehouse_aug_is_synthetic_and_not_leaked():
    rows, stats = data.prepare(list(data.aug_files([config.WEB_SET])))
    assert len(rows) >= 100 and stats["train_rows"] == len(rows)
    for r in rows:
        assert r["label"] == "none" or r["label"].split(":")[0] in config.WEB_CONNECTORS, r
    evals = [set(data.norm(o["text"]).split()) for n in (*config.EVAL_SETS, config.WEB_SET) for o in data.load_eval(n)]
    for r in rows:
        s = set(data.norm(r["text"]).split())
        assert max(data.jaccard(s, e) for e in evals) < 0.5, r["text"]


def test_web_tier_layout():
    web, accurate = config.tier("web"), config.tier("accurate")
    assert web.source == "web" and web.base_model == accurate.base_model and web.revision == accurate.revision
    assert config.holdout_sets("web") == (*config.EVAL_SETS, config.WEB_SET)
    assert config.holdout_sets("accurate") == config.EVAL_SETS
    from tools.intent_model import pipeline

    names = [*config.EVAL_SETS, "warehouse.cal", "warehouse.test"]
    g = pipeline._groups(web, names)
    assert g["test"] == ["warehouse.test"] and "warehouse.test" not in g["dev"] and "warehouse.cal" in g["dev"]
    g = pipeline._groups(config.tier("accurate"), list(config.EVAL_SETS))
    assert g["dev"] == ["fresh"] and g["test"] == ["held2", "held3"]


def test_web_threshold_keeps_own_calibration_in_budget_with_margin():
    from tools.intent_model import pipeline

    def ev(label, rule="ok"):
        return {"label": label, "rule_outcome": rule}

    def pr(label, sim):
        return {"pred": label, "sim": sim, "second": None}

    fresh_eval = [ev("warehouse:warehouse.where", "none"), ev("warehouse:warehouse.me", "none"), ev("warehouse:warehouse.price", "none")]
    fresh_eval += [ev("none") for _ in range(100)]
    fresh_pred = [pr("warehouse:warehouse.where", 0.8), pr("warehouse:warehouse.me", 0.94), pr("warehouse:warehouse.price", 0.99)]
    fresh_pred += [pr("none", 0.99) for _ in range(100)]
    # 2/20 = 10 % ложных тревог на cal при 0,8: общая dev этого скрывает.
    cal_eval = [ev("none") for _ in range(20)]
    cal_pred = [pr("warehouse:warehouse.where", 0.8), pr("warehouse:warehouse.me", 0.9)]
    cal_pred += [pr("none", 0.99) for _ in range(18)]
    per_set = {
        "fresh": (fresh_eval, fresh_pred),
        "warehouse.cal": (cal_eval, cal_pred),
        # Значения test нарочно противоположные: выбор не должен их читать.
        "warehouse.test": (cal_eval, [pr("none", 0.99) for _ in range(20)]),
    }
    assert knn.pick_threshold(*pipeline._merge(per_set, ["fresh", "warehouse.cal"])) == 0.8
    assert pipeline._pick_threshold(config.tier("web"), per_set) == 0.95


def test_web_threshold_margin_falls_back_when_it_breaks_budget():
    """Запас +0,01 строже, но доля неверных среди подсказок там больше бюджета — остаётся выбранный порог."""
    from tools.intent_model import pipeline

    def ev(label, rule="none"):
        return {"label": label, "rule_outcome": rule}

    def pr(label, sim):
        return {"pred": label, "sim": sim, "second": None}

    lab = "warehouse:warehouse.where"
    fresh_eval = [ev(lab) for _ in range(21)]
    # 10 верных на 0,80 и 10 на 0,95, одна неверная на 0,96: при 0,80 неверных 1/21 (4,8 %),
    # строже 0,80 — 1/11 (9,1 %), уже вне бюджета.
    fresh_pred = [pr(lab, 0.80) for _ in range(10)] + [pr(lab, 0.95) for _ in range(10)] + [pr("warehouse:warehouse.me", 0.96)]
    cal_eval = [ev("none", "ok") for _ in range(20)]
    cal_pred = [pr("none", 0.99) for _ in range(20)]
    per_set = {"fresh": (fresh_eval, fresh_pred), "warehouse.cal": (cal_eval, cal_pred), "warehouse.test": (cal_eval, cal_pred)}
    assert pipeline._pick_threshold(config.tier("web"), per_set) == 0.8


def test_holdout_probes_are_training_texts_only():
    from tools.intent_model import pipeline

    rows = [{"text": f"фраза {i}", "label": "x"} for i in range(1000)]
    probes = pipeline._probe_texts(rows)
    assert len(probes) == 128 and set(probes) <= {r["text"] for r in rows}
    assert probes == pipeline._probe_texts(rows)
    assert pipeline._probe_texts(rows[:5]) == [r["text"] for r in rows[:5]]


def test_warehouse_aug_teaches_bare_times_are_not_calc():
    rows, _ = data.prepare(list(data.aug_files([config.WEB_SET])))
    times = [r for r in rows if re.fullmatch(r"(?:в|к|на|около)?\s*\d{1,2}(?::\d{2})?", r["text"])]
    assert len(times) >= 10 and all(r["label"] == "none" for r in times)


# Те же случаи — test/intent/bare_time_test.dart (разбор один в Dart и здесь).
BARE_TIME_YES = ["7:30", "в 9", "нет, на 6:45", "к 6 вечера", "часам к 5", "около 7", "18:30", "в 10."]
BARE_TIME_NO = ["15", "7+30", "2*9", "в 9 разбуди", "12.11", "сколько будет 7:30", "в 25", "7:75", ""]


def test_bare_time_guard():
    from tools.intent_model import pipeline

    assert all(data.bare_time(t) for t in BARE_TIME_YES)
    assert not any(data.bare_time(t) for t in BARE_TIME_NO)
    assert config.tier("web").time_guard
    assert not config.tier("accurate").time_guard
    evals = [{"text": "7:30"}, {"text": "где 100200"}]
    preds = [{"pred": "calc:calc.eval", "sim": 0.99, "second": None}, {"pred": "warehouse:warehouse.where", "sim": 0.9, "second": None}]
    got = pipeline._guard(config.tier("web"), evals, preds)
    assert [p["pred"] for p in got] == ["none", "warehouse:warehouse.where"]
    assert pipeline._guard(config.tier("accurate"), evals, preds) == preds
