"""Регрессии по итогам проверки инструмента: по тесту на каждую подтверждённую находку."""

from __future__ import annotations

import io
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from corpus_gen import cli, pipeline
from corpus_gen.config import Source
from corpus_gen.providers import AnthropicProvider, ProviderError, RateLimiter
from corpus_gen.store import CandidateStore, read_jsonl

from test_pipeline import LABEL_CREATE, FakeProvider, config_for, label_responder, make_source, project  # noqa: F401


def test_unicode_line_separators_do_not_corrupt_store(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    phrase = "Добавь «Отчёт по продажам» завтра\u0085"
    pipeline.generate(
        config, store, "create", 1, [make_source("g", "g")], factory=lambda s: FakeProvider(s, lambda *_: {"phrases": [phrase]})
    )
    reloaded = CandidateStore(config.work_dir)
    assert [r["text"] for r in reloaded.rows] == ["Добавь «Отчёт по продажам» завтра"]


def test_read_jsonl_keeps_separator_inside_json_string(tmp_path: Path) -> None:
    path = tmp_path / "x.jsonl"
    path.write_text('{"text": "a b"}\n{"text": "c"}\n', encoding="utf-8")
    assert [r["text"] for r in read_jsonl(path)] == ["a b", "c"]


@pytest.mark.parametrize(
    ("due", "precision", "expected"),
    [
        ("2026-11-03T00:00:00", "date", ("2026-11-03", "date")),
        ("2026-11-03", "date", ("2026-11-03", "date")),
        ("2026-11-03T10:00", "dateTime", ("2026-11-03T10:00", "dateTime")),
        ("2026-11-03T10:00", None, ("2026-11-03T10:00", "dateTime")),
    ],
)
def test_due_respects_model_precision(due: str, precision: Any, expected: tuple[str, str]) -> None:
    label = pipeline.normalize_label({**LABEL_CREATE, "due": due, "precision": precision})
    assert (label["due"], label["precision"]) == expected


@pytest.mark.parametrize(
    ("due", "precision"),
    [
        ("2026-11-03T10:00", "date"),
        ("2026-11-03", "dateTime"),
        ("0999-11-03", "date"),
        ("2026-11-03", "week"),
    ],
)
def test_contradictory_or_odd_due_is_rejected(due: str, precision: Any) -> None:
    with pytest.raises(ProviderError):
        pipeline.normalize_label({**LABEL_CREATE, "due": due, "precision": precision})


def test_limit_does_not_get_stuck_on_failing_row(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Плохая фраза", "Добавь задачу «Купить хлеб» завтра"], "web")

    def respond(_system: str, user: str) -> dict[str, Any]:
        if "Плохая" in user:
            raise ProviderError("всегда ошибка")
        return dict(LABEL_CREATE)

    labelers = [make_source("l1", "x"), make_source("l2", "y")]
    for _ in range(2):
        pipeline.label(config, store, labelers, limit=1, factory=lambda s: FakeProvider(s, respond))
    assert [r["status"] for r in store.rows] == ["error", "agreed"]


def test_rows_without_eligible_labelers_are_skipped(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Добавь задачу «Купить хлеб» завтра"], "web")
    store.rows[0]["family"] = "x"
    counts = pipeline.label(config, store, [make_source("l1", "x")], factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)))
    assert not counts and store.rows[0]["status"] == "new"


def test_usage_is_recorded_for_invalid_answers(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Добавь задачу «Купить хлеб» завтра"], "web")
    bad = {**LABEL_CREATE, "intent": "delete"}
    pipeline.label(config, store, [make_source("l1", "x"), make_source("l2", "y")], factory=lambda s: FakeProvider(s, label_responder(bad)))
    assert len(store.usage()) == 2
    assert store.rows[0]["status"] == "error"


def test_tags_name_only_labelers_that_produced_final(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Добавь задачу «Купить хлеб» завтра"], "web")
    store.rows[0]["labels"]["removed"] = dict(LABEL_CREATE)
    labelers = [make_source("l1", "x"), make_source("l2", "y")]
    pipeline.label(config, store, labelers, factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)))
    assert pipeline.corpus_line(store.rows[0])["tags"][1] == "labels:l1,l2"


def _anthropic(content: list[Any], stop_reason: str = "end_turn") -> AnthropicProvider:
    provider = object.__new__(AnthropicProvider)
    provider.source = Source(name="sonnet", kind="anthropic", family="anthropic", model="m", roles=frozenset({"generate"}), fallbacks="default")
    provider._limiter = RateLimiter(10_000)
    response = SimpleNamespace(content=content, stop_reason=stop_reason, usage=SimpleNamespace(input_tokens=5, output_tokens=7))
    create = lambda **_: response  # noqa: E731
    provider._client = SimpleNamespace(messages=SimpleNamespace(create=create), beta=SimpleNamespace(messages=SimpleNamespace(create=create)))
    return provider


def test_fallback_response_uses_text_after_fallback_block() -> None:
    provider = _anthropic(
        [
            SimpleNamespace(type="text", text='{"intent":"crea'),
            SimpleNamespace(type="fallback"),
            SimpleNamespace(type="text", text='{"phrases": ["ok"]}'),
        ]
    )
    completion = provider.complete("s", "u", {})
    assert completion.data == {"phrases": ["ok"]}
    assert (completion.input_tokens, completion.output_tokens) == (5, 7)


def test_refusal_keeps_token_usage() -> None:
    provider = _anthropic([], stop_reason="refusal")
    with pytest.raises(ProviderError) as error:
        provider.complete("s", "u", {})
    assert (error.value.input_tokens, error.value.output_tokens) == (5, 7)


def test_import_manual_strips_bom_and_handles_missing_file(project: Path, capsys: pytest.CaptureFixture[str]) -> None:
    config_path = project / "tools" / "corpus_gen" / "config.toml"
    phrases = project / "phrases.txt"
    phrases.write_bytes("﻿1. Покажи мои задачи\r\n2. Привет\r\n".encode("utf-8"))
    assert cli.main(["--config", str(config_path), "import-manual", str(phrases), "--source", "web"]) == 0
    texts = [r["text"] for r in CandidateStore(config_for(project).work_dir).rows]
    assert texts == ["Покажи мои задачи", "Привет"]
    assert cli.main(["--config", str(config_path), "import-manual", str(project / "nope.txt"), "--source", "web"]) == 2


def test_review_saves_on_eof(project: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Фраза один", "Фраза два"], "web")
    for row in store.rows:
        row["status"] = "disputed"
        row["labels"] = {"l1": {**LABEL_CREATE}}
    store.save()
    monkeypatch.setattr("sys.stdin", io.StringIO("1\n"))  # первая решена, затем EOF
    config_path = project / "tools" / "corpus_gen" / "config.toml"
    assert cli.main(["--config", str(config_path), "review"]) == 0
    statuses = [r["status"] for r in CandidateStore(config.work_dir).rows]
    assert statuses == ["accepted", "disputed"]
