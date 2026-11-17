"""promote сверяет с приложением каждую фразу — и разметку из review тоже.

Регрессия: promote писал фразы коннекторов кроме tasks как active без проверки (unverified),
а фразы tasks сверял только с ScenarioParser, без маршрутизации. Разметка, принятая вручную
в review (final_by [разметчик, "manual"]), check_with_app не проходит, поэтому 220 таких
строк легли в generated.jsonl как active и упали в flutter test test/scenario_corpus_test.dart.

fixtures/promote_reviewed_rows.jsonl — фразы из того корпуса с разметкой из review и ответ
tool/route_phrases.dart на них (routed), status — что корпусный тест ждёт от строки.
Ответы записаны с настоящего dart до исправления правил (HEAD ea9dc88): это снимок
приложения, в котором фразы ещё не разбирались. После исправлений настоящий dart отвечает на
них иначе, поэтому test_fixture_matches_real_router (CORPUS_GEN_DART_TESTS=1) сверяет с ним
формат ответа — поля верхнего уровня, совпадений и разбора, — а не сами команды.
"""

from __future__ import annotations

import dataclasses
import json
import os
from pathlib import Path
from typing import Any

import pytest

from corpus_gen import pipeline
from corpus_gen.store import CandidateStore, read_jsonl

from test_passwords import REPO, _dart
from test_pipeline import config_for, project  # noqa: F401
from test_single_labeler import FakeRouter

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "promote_reviewed_rows.jsonl"
CASES: list[dict[str, Any]] = [json.loads(line) for line in FIXTURE.read_text(encoding="utf-8").splitlines() if line]


def _accept_in_review(config: Any, store: CandidateStore) -> None:
    """Фразы, размеченные одной моделью и принятые владельцем в review."""
    for case in CASES:
        topic = "manual" if case["connector"] == "tasks" else f"{case['connector']}:manual"
        pipeline.import_manual(config, store, [case["text"]], "ollama", topic)
    by_text = {c["text"]: c for c in CASES}
    for row in store.rows:
        final = dict(by_text[row["text"]]["final"])
        row.update(status="accepted", final=final, final_by=["gemma", "manual"], labels={"gemma": final})
    store.save()


def test_reviewed_rows_are_checked_like_corpus_test(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    _accept_in_review(config, store)
    router = FakeRouter({c["text"]: c["routed"] for c in CASES})

    counts = pipeline.promote(config, store, router=router)

    expected_gaps = sum(c["status"] == "known_gap" for c in CASES)
    assert counts == {"active": len(CASES) - expected_gaps, "known_gap": expected_gaps}
    # Маршрутизатору — все фразы одним вызовом, а не только фразы tasks.
    assert router.calls == [[c["text"] for c in CASES]]
    lines = {line["text"]: line for line in read_jsonl(config.corpus_dir / pipeline.GENERATED_FILE)}
    for case in CASES:
        line = lines[case["text"]]
        assert line.get("status", "active") == case["status"], case["text"]
        assert ("note" in line) == (case["status"] == "known_gap")
        assert line["tags"][-1] == "labels:gemma,manual"
    # Причина — как её видит приложение: кто забрал фразу и какой commandId вернул.
    assert lines["что делать с паролями если телефон потерян"]["note"] == (
        "приложение сейчас: коннектор=никто, intent=unknown"
    )
    assert lines["Лиорио, а мой пароль от банка не слишком простой?"]["note"] == (
        "приложение сейчас: intent=passwords.hint"
    )
    # Фраза tasks, которую забирает другой коннектор, — known_gap, хотя ScenarioParser согласен.
    assert lines["запиши: пароль от wifi забыл"]["note"] == "приложение сейчас: коннектор=passwords"
    assert {r["status"] for r in store.rows} == {"promoted"}


def test_missing_or_failed_router_result_keeps_row_accepted(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    _accept_in_review(config, store)
    answers = {c["text"]: c["routed"] for c in CASES[1:]}
    answers[CASES[1]["text"]] = {"error": "boom"}

    counts = pipeline.promote(config, store, router=FakeRouter(answers))

    assert counts["parser_error"] == 2
    unchecked = {CASES[0]["text"], CASES[1]["text"]}
    assert {r["text"] for r in store.rows if r["status"] == "accepted"} == unchecked
    assert unchecked.isdisjoint(line["text"] for line in read_jsonl(config.corpus_dir / pipeline.GENERATED_FILE))


def test_router_crash_writes_nothing(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    _accept_in_review(config, store)
    with pytest.raises(RuntimeError):
        pipeline.promote(config, store, router=FakeRouter(error=RuntimeError("dart упал")))
    assert not (config.corpus_dir / pipeline.GENERATED_FILE).exists()
    assert {r["status"] for r in CandidateStore(config.work_dir).rows} == {"accepted"}


@pytest.mark.skipif(
    os.environ.get("CORPUS_GEN_DART_TESTS") != "1" or _dart() is None,
    reason="настоящий dart: CORPUS_GEN_DART_TESTS=1 (долго — компиляция tool/route_phrases.dart)",
)
def test_fixture_matches_real_router(project: Path) -> None:
    config = dataclasses.replace(config_for(project), project_root=REPO, dart=_dart())
    items = [{"cid": str(i), "text": c["text"], "now": pipeline.CORPUS_DEFAULT_NOW} for i, c in enumerate(CASES)]
    results = pipeline.run_dart_router(config, items)
    for i, case in enumerate(CASES):
        got = {k: v for k, v in results[str(i)].items() if k != "id"}
        recorded = case["routed"]
        assert set(got) == set(recorded), case["text"]
        assert set(got["parse"]) == set(recorded["parse"]), case["text"]
        match_keys = {"connector", "command", "confidence", "implicit", "fallback"}
        for match in got["matches"] + recorded["matches"]:
            assert set(match) == match_keys, case["text"]
