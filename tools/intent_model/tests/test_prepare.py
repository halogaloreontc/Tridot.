"""Подготовка данных и метрики — без моделей и сети."""

import json

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
