"""Массовые команды (rescheduleMany, completeMany): поля scope и shift разметки и корпуса."""

from __future__ import annotations

from typing import Any

import pytest

from corpus_gen import pipeline, prompts
from corpus_gen.providers import ProviderError


def _label(**fields: Any) -> dict[str, Any]:
    base = {"title": None, "due": None, "precision": None, "issue": "none", "titleIssue": "none"}
    return {**base, **fields, "confident": True, "comment": ""}


def _row(final: dict[str, Any]) -> dict[str, Any]:
    return {
        "cid": "b1",
        "text": "перенеси всё на выходные",
        "now": pipeline.CORPUS_DEFAULT_NOW,
        "source": "s",
        "topic": "bulk",
        "final_by": ["a", "b"],
        "final": final,
    }


def test_label_fields_and_schema_have_scope_and_shift() -> None:
    assert prompts.LABEL_FIELDS[-2:] == ("scope", "shift")
    schema = prompts.label_schema(pipeline._builtin_tasks())
    assert {"scope", "shift"} <= set(schema["required"])
    assert "rescheduleMany" in schema["properties"]["intent"]["enum"]
    assert "completeMany" in prompts.LABEL_SYSTEM and "scope" in prompts.LABEL_SYSTEM


def test_normalize_bulk_scope_tags_and_shift() -> None:
    label = pipeline.normalize_label(
        _label(intent="rescheduleMany", title="Всё", due="2026-11-09", scope="overdue #Работа #работа")
    )
    assert label["title"] is None
    assert label["scope"] == "overdue #работа"
    assert label["shift"] is None and label["due"] == "2026-11-09"
    shifted = pipeline.normalize_label(_label(intent="rescheduleMany", due="2026-11-02T17:30", shift="+1w"))
    assert shifted["scope"] == "all"
    assert shifted["shift"] == "+7d"
    assert shifted["due"] is None and shifted["precision"] is None
    done = pipeline.normalize_label(_label(intent="completeMany", scope="date:2026-11-02", shift="+1h"))
    assert done["scope"] == "date:2026-11-02" and done["shift"] is None and done["due"] is None


def test_scope_and_shift_are_null_for_other_intents() -> None:
    label = pipeline.normalize_label(_label(intent="rescheduleTask", title="Отчёт", scope="all", shift="+1h"))
    assert label["scope"] is None and label["shift"] is None


@pytest.mark.parametrize("scope", ["всё", "date:2026-13-40", "overdue работа", 5])
def test_bad_scope_is_a_labeling_error(scope: Any) -> None:
    with pytest.raises(ProviderError):
        pipeline.normalize_label(_label(intent="completeMany", scope=scope))


@pytest.mark.parametrize("shift", ["1h", "+0d", "+2y", "позже"])
def test_bad_shift_is_a_labeling_error(shift: str) -> None:
    with pytest.raises(ProviderError):
        pipeline.normalize_label(_label(intent="rescheduleMany", shift=shift))


def test_corpus_line_writes_scope_and_shift_only_for_bulk() -> None:
    final = {k: None for k in prompts.LABEL_FIELDS} | {
        "intent": "rescheduleMany",
        "due": "2026-11-07",
        "precision": "date",
        "issue": "none",
        "titleIssue": "none",
        "scope": "all",
    }
    line = pipeline.corpus_line(_row(final))
    assert line["scope"] == "all" and "shift" not in line
    assert line["title"] is None and line["due"] == "2026-11-07"
    shifted = pipeline.corpus_line(_row(final | {"due": None, "precision": None, "shift": "+1h"}))
    assert shifted["shift"] == "+1h"
    single = pipeline.corpus_line(_row(final | {"intent": "rescheduleTask", "title": "Отчёт"}))
    assert "scope" not in single and "shift" not in single


def test_old_final_without_scope_still_promotes() -> None:
    """Разметки, сделанные до scope и shift, читаются без изменений."""
    old_final = {"intent": "completeMany", "title": None, "due": None, "precision": None, "issue": "none", "titleIssue": "none"}
    line = pipeline.corpus_line(_row(old_final))
    assert line["scope"] == "all"
    parsed = {"intent": "completeMany", "title": None, "issue": "none", "titleIssue": "none", "scope": "all", "shift": None}
    assert pipeline.parser_mismatches(line, old_final, parsed) == []
    assert pipeline.parser_mismatches(line, old_final, parsed | {"scope": "overdue"}) == ["scope='overdue'"]
    # Старая разметка одной задачи без scope сравнивается как прежде.
    single = {"intent": "listTasks", "title": None, "due": None, "precision": None, "issue": "none", "titleIssue": "none"}
    assert pipeline.comparable(single) == pipeline.comparable({**single, "scope": None, "shift": None})
