"""Пробы задач «Продвинутой», ради которых её берут (ADR-046, п. 2).

- **Поля в карточку** (`eval/fields.jsonl`): из фразы — JSON
  `{title, date, time}` по схеме (грамматика). Сегодня — пятница,
  2026-11-20, 12:00. Метрики — доля верных дат, времени, названий и фраз,
  где верно всё.
- **Таблицы** (`eval/tables.jsonl`, `eval/tables/*.csv`): модель только
  переводит вопрос в запрос (`op`, `column`, `filters`), считает код —
  `run_query`. Метрика — доля верных ответов.
- **Пересказ** (`eval/summary.jsonl`): доля сохранённых фактов и пересказы
  с числами, которых нет в тексте.

Все данные синтетические.
"""

from __future__ import annotations

import csv
import json
import re
from pathlib import Path

from . import config

EVAL = config.PKG / "eval"
TODAY = "2026-11-20"
TODAY_TEXT = "Сегодня пятница, 20 ноября 2026 года, 12:00."

OPS = ("sum", "count", "avg", "min", "max", "list")
CMPS = ("eq", "ne", "gt", "lt", "ge", "le", "contains")


def read_jsonl(name: str) -> list[dict]:
    return [json.loads(line) for line in (EVAL / name).read_text(encoding="utf-8").splitlines() if line.strip()]


# --- поля в карточку

FIELDS_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        # Без pattern: перевод схемы в грамматику llama-cpp-python 0.3.38
        # портит \d{n}. Формат проверяет сравнение с ответом.
        "date": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "time": {"anyOf": [{"type": "string"}, {"type": "null"}]},
    },
    "required": ["title", "date", "time"],
}

FIELDS_SYSTEM = (
    "Ты собираешь карточку задачи из фразы пользователя. " + TODAY_TEXT + "\n"
    "Верни JSON: title — что сделать, коротко, без даты и времени; "
    "date — дата в формате ГГГГ-ММ-ДД или null, если её нет; "
    "time — время ЧЧ:ММ в 24-часовом формате или null, если его нет. "
    "«До 17:00» — это время 17:00."
)


def fields_score(rows: list[dict], outs: list[dict | None]) -> dict:
    n = len(rows)
    ok = {"title": 0, "date": 0, "time": 0, "all": 0, "valid_json": 0}
    for r, o in zip(rows, outs):
        if o is None:
            continue
        ok["valid_json"] += 1
        title = str(o.get("title") or "").lower()
        t_ok = all(s in title for s in r["title_has"])
        d_ok = o.get("date") == r["date"]
        h_ok = o.get("time") == r["time"]
        ok["title"] += t_ok
        ok["date"] += d_ok
        ok["time"] += h_ok
        ok["all"] += t_ok and d_ok and h_ok
    return {k: round(100 * v / n, 1) for k, v in ok.items()} | {"phrases": n}


# --- таблицы


def load_table(name: str) -> list[dict]:
    with open(EVAL / "tables" / f"{name}.csv", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def _num(v) -> float | None:
    try:
        return float(str(v).replace(",", ".").replace(" ", ""))
    except ValueError:
        return None


def _match(row: dict, f: dict) -> bool:
    have, want, cmp = row.get(f["column"]), f["value"], f["cmp"]
    if have is None:
        return False
    if cmp == "contains":
        return str(want).lower() in str(have).lower()
    a, b = _num(have), _num(want)
    if cmp in ("eq", "ne"):
        same = a == b if a is not None and b is not None else str(have).strip().lower() == str(want).strip().lower()
        return same if cmp == "eq" else not same
    if a is None or b is None:
        return False
    return {"gt": a > b, "lt": a < b, "ge": a >= b, "le": a <= b}[cmp]


def run_query(rows: list[dict], q: dict):
    """Запрос по таблице: число или список значений столбца."""
    hit = [r for r in rows if all(_match(r, f) for f in q.get("filters") or [])]
    op, col = q["op"], q.get("column")
    if op == "count":
        return len(hit)
    if op == "list":
        return [r.get(col) for r in hit]
    vals = [v for v in (_num(r.get(col)) for r in hit) if v is not None]
    if not vals:
        return None
    return {"sum": sum(vals), "avg": sum(vals) / len(vals), "min": min(vals), "max": max(vals)}[op]


def answer_ok(got, want) -> bool:
    if isinstance(got, list):
        got = got[0] if len(got) == 1 else None
    if isinstance(want, str):
        return got is not None and str(got).strip().lower() == want.lower()
    g = _num(got) if got is not None else None
    return g is not None and abs(g - want) < 0.01


def table_schema(columns: list[str]) -> dict:
    return {
        "type": "object",
        "properties": {
            "op": {"enum": list(OPS)},
            "column": {"anyOf": [{"enum": columns}, {"type": "null"}]},
            "filters": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "column": {"enum": columns},
                        "cmp": {"enum": list(CMPS)},
                        "value": {"anyOf": [{"type": "string"}, {"type": "number"}]},
                    },
                    "required": ["column", "cmp", "value"],
                },
            },
        },
        "required": ["op", "column", "filters"],
    }


def table_system(rows: list[dict]) -> str:
    cols = list(rows[0])
    head = ",".join(cols)
    sample = "\n".join(",".join(str(r[c]) for c in cols) for r in rows[:3])
    return (
        "Ты переводишь вопрос о таблице в запрос. Считать будет программа, ты — только запрос.\n"
        f"Столбцы: {head}\nПервые строки:\n{sample}\n"
        "Верни JSON: op — sum (сумма), count (сколько строк), avg (среднее), min, max или list "
        "(значения столбца); column — столбец для op (для count — null); filters — условия на строки: "
        "column, cmp (eq, ne, gt, lt, ge, le, contains), value. Имена и названия ищи через contains."
    )


# --- пересказ

SUMMARY_SYSTEM = "Перескажи текст пользователя в одном-двух предложениях по-русски. Сохрани числа, даты и имена. Ничего не добавляй от себя."

_NUM = re.compile(r"\d+(?:[.,:]\d+)?")


def summary_score(rows: list[dict], outs: list[str]) -> dict:
    kept = total = invented = 0
    for r, o in zip(rows, outs):
        low = o.lower()
        for fact in r["facts"]:
            total += 1
            kept += fact.lower() in low
        source = set(_NUM.findall(r["text"]))
        invented += any(n not in source for n in _NUM.findall(o))
    return {
        "facts_kept": round(100 * kept / total, 1),
        "with_invented_numbers": round(100 * invented / len(rows), 1),
        "texts": len(rows),
    }
