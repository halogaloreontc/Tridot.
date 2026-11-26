"""Пробы задач: эталонные запросы дают записанные ответы; оценки полей и пересказа."""

from datetime import date

import pytest

from tools.gen_model import tasks

GOLD = {
    "tb-01": {"op": "sum", "column": "остаток", "filters": []},
    "tb-02": {"op": "list", "column": "остаток", "filters": [{"column": "товар", "cmp": "contains", "value": "кефир"}]},
    "tb-03": {"op": "count", "column": None, "filters": [{"column": "остаток", "cmp": "eq", "value": 0}]},
    "tb-04": {"op": "list", "column": "цена", "filters": [{"column": "товар", "cmp": "contains", "value": "сок"}]},
    "tb-05": {"op": "sum", "column": "остаток", "filters": [{"column": "ячейка", "cmp": "eq", "value": "B1"}]},
    "tb-06": {"op": "count", "column": None, "filters": [{"column": "цена", "cmp": "gt", "value": 100}]},
    "tb-07": {"op": "max", "column": "цена", "filters": []},
    "tb-08": {"op": "avg", "column": "цена", "filters": []},
    "tb-09": {"op": "list", "column": "ячейка", "filters": [{"column": "товар", "cmp": "contains", "value": "вода"}]},
    "tb-10": {"op": "count", "column": None, "filters": [{"column": "остаток", "cmp": "lt", "value": 10}]},
    "tb-11": {"op": "sum", "column": "остаток", "filters": [{"column": "ячейка", "cmp": "eq", "value": "A1"}]},
    "tb-12": {"op": "list", "column": "товар", "filters": [{"column": "артикул", "cmp": "eq", "value": "B-203"}]},
    "tb-13": {"op": "sum", "column": "сумма", "filters": [{"column": "поставщик", "cmp": "contains", "value": "Ромашка"}]},
    "tb-14": {"op": "count", "column": None, "filters": []},
    "tb-15": {"op": "count", "column": None, "filters": [{"column": "поставщик", "cmp": "contains", "value": "Сидоров"}]},
    "tb-16": {"op": "sum", "column": "количество", "filters": [{"column": "товар", "cmp": "contains", "value": "вода"}]},
    "tb-17": {"op": "max", "column": "сумма", "filters": []},
    "tb-18": {"op": "sum", "column": "сумма", "filters": []},
    "tb-19": {"op": "count", "column": None, "filters": [{"column": "дата", "cmp": "eq", "value": "2026-11-19"}]},
    "tb-20": {"op": "list", "column": "поставщик", "filters": [{"column": "товар", "cmp": "contains", "value": "сок"}]},
    "tb-21": {"op": "avg", "column": "сумма", "filters": []},
    "tb-22": {"op": "count", "column": None, "filters": [{"column": "сумма", "cmp": "gt", "value": 3000}]},
    "tb-23": {"op": "sum", "column": "количество", "filters": [{"column": "поставщик", "cmp": "contains", "value": "Родник"}]},
    "tb-24": {"op": "min", "column": "количество", "filters": []},
}


def test_table_answers_match_gold_queries():
    rows = tasks.read_jsonl("tables.jsonl")
    assert {r["id"] for r in rows} == set(GOLD)
    for r in rows:
        got = tasks.run_query(tasks.load_table(r["table"]), GOLD[r["id"]])
        assert tasks.answer_ok(got, r["answer"]), (r["id"], got, r["answer"])


def test_wrong_answer_rejected():
    assert not tasks.answer_ok(191, 192)
    assert not tasks.answer_ok(["C1", "C2"], "C2")
    assert tasks.answer_ok(["C2"], "c2")


def test_fields_probe_dates_are_real():
    assert date.fromisoformat(tasks.TODAY).weekday() == 4  # пятница
    for r in tasks.read_jsonl("fields.jsonl"):
        if r["date"]:
            assert date.fromisoformat(r["date"]) >= date.fromisoformat(tasks.TODAY)
    weekdays = {"fd-03": 0, "fd-07": 2, "fd-09": 1, "fd-13": 3, "fd-15": 6, "fd-17": 5, "fd-23": 1, "fd-30": 4}
    by_id = {r["id"]: r for r in tasks.read_jsonl("fields.jsonl")}
    for k, wd in weekdays.items():
        assert date.fromisoformat(by_id[k]["date"]).weekday() == wd, k


def test_fields_score():
    rows = [{"title_has": ["банк"], "date": "2026-11-21", "time": "09:00"}, {"title_has": ["кот"], "date": None, "time": None}]
    outs = [{"title": "Позвонить в банк", "date": "2026-11-21", "time": "09:00"}, None]
    s = tasks.fields_score(rows, outs)
    assert s["all"] == 50.0 and s["valid_json"] == 50.0


def test_summary_score_flags_invented_numbers():
    rows = [{"text": "Пришло 40 коробок, 6 с браком.", "facts": ["40", "6"]}]
    assert tasks.summary_score(rows, ["Пришло 40 коробок, 6 с браком."])["with_invented_numbers"] == 0.0
    s = tasks.summary_score(rows, ["Пришло 41 коробка."])
    assert s["with_invented_numbers"] == 100.0 and s["facts_kept"] == pytest.approx(0.0)
