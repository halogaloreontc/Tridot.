"""Фразы с единственным разметчиком: сверка с приложением (settings.single_labeler_check)."""

from __future__ import annotations

import dataclasses
import io
from pathlib import Path
from typing import Any

import pytest

from corpus_gen import cli, pipeline
from corpus_gen.store import CandidateStore

from test_pipeline import LABEL_CREATE, FakeProvider, config_for, label_responder, make_source, project  # noqa: F401

# Как у пользователя: два источника двух семейств, оба генерируют и размечают.
OLLAMA = make_source("ollama", "local")
GEMMA = make_source("gemma", "google")
LABELERS = [OLLAMA, GEMMA]

TASK_TEXT = "Добавь задачу «Купить хлеб» завтра"

# Ответ tool/route_phrases.dart для TASK_TEXT, совпадающий с LABEL_CREATE.
ROUTED_CREATE = {
    "connector": "tasks",
    "command": "task.create",
    "matches": [{"connector": "tasks", "command": "task.create", "confidence": 0.9, "implicit": False, "fallback": False}],
    "parse": {
        "intent": "createTask",
        "title": "Купить хлеб",
        "targetQuery": None,
        "due": "2026-11-03",
        "precision": "date",
        "issue": "none",
        "titleIssue": "none",
        "projects": [],
    },
}


class FakeRouter:
    """Подделка run_dart_router: ответы по тексту фразы, запоминает вызовы."""

    def __init__(self, answers: dict[str, dict[str, Any]] | None = None, error: Exception | None = None) -> None:
        self.answers = answers or {}
        self.error = error
        self.calls: list[list[str]] = []

    def __call__(self, _config: Any, items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        self.calls.append([i["text"] for i in items])
        if self.error:
            raise self.error
        return {i["cid"]: {"id": i["cid"], **self.answers[i["text"]]} for i in items if i["text"] in self.answers}


def add_rows(config: Any, store: CandidateStore, texts: list[str], connector: str = "tasks") -> None:
    """Фразы, сгенерированные ollama: разметить их может только gemma."""
    topic = "manual" if connector == "tasks" else f"{connector}:manual"
    pipeline.import_manual(config, store, texts, "ollama", topic)
    for row in store.rows:
        row["family"] = "local"


def no_models(source: Any) -> FakeProvider:
    def boom(*_: Any) -> dict[str, Any]:
        raise AssertionError("модели вызываться не должны")

    return FakeProvider(source, boom)


def run(config: Any, store: CandidateStore, label: dict[str, Any], router: FakeRouter, labelers=LABELERS):
    return pipeline.label(
        config, store, labelers, factory=lambda s: FakeProvider(s, label_responder(label)), router=router
    )


def test_single_confident_label_matching_app_is_agreed(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT, "Добавь задачу «Спорт» завтра"])
    sport = {**ROUTED_CREATE, "parse": {**ROUTED_CREATE["parse"], "title": "Спорт"}}
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE, "Добавь задачу «Спорт» завтра": sport})
    counts = run(config, store, LABEL_CREATE, router)
    assert len(router.calls) == 1 and len(router.calls[0]) == 2  # один процесс dart на все фразы
    first, second = CandidateStore(config.work_dir).rows
    assert set(first["labels"]) == {"gemma"}
    assert first["status"] == "agreed"
    assert first["final_by"] == ["gemma", pipeline.APP_CHECK_MARK]
    assert first["final"]["title"] == "Купить хлеб"
    assert "check" not in first
    # Разметчик ошибся в названии второй фразы, парсер — нет: спорная.
    assert second["status"] == "disputed" and "final" not in second
    assert second["check"] == "приложение: title='Спорт'"
    assert counts["agreed"] == 1 and counts["disputed"] == 1
    assert counts[pipeline.AGREED_BY_PARSER] == 1
    assert pipeline.corpus_line(first)["tags"][1] == "labels:gemma,parser"


def test_mismatch_keeps_disputed_with_note(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    parse = {**ROUTED_CREATE["parse"], "due": "2026-11-04"}
    run(config, store, LABEL_CREATE, FakeRouter({TASK_TEXT: {**ROUTED_CREATE, "parse": parse}}))
    row = store.rows[0]
    assert row["status"] == "disputed"
    assert row["check"] == "приложение: due='2026-11-04'"


def test_not_confident_is_disputed_without_check(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    run(config, store, {**LABEL_CREATE, "confident": False}, router)
    assert not router.calls
    assert store.rows[0]["status"] == "disputed"
    assert "не уверен" in store.rows[0]["check"]


def test_tasks_phrase_routed_elsewhere_is_disputed(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    run(config, store, LABEL_CREATE, FakeRouter({TASK_TEXT: {**ROUTED_CREATE, "connector": "ambiguous", "command": None}}))
    assert store.rows[0]["status"] == "disputed"
    assert store.rows[0]["check"] == "приложение: коннектор=ambiguous"


CALC = {"intent": "calc.evaluate", "confident": True, "comment": ""}
CALC_MATCH = {"connector": "calc", "command": "calc.evaluate", "confidence": 0.9, "implicit": False, "fallback": False}
UNKNOWN_PARSE = {**ROUTED_CREATE["parse"], "intent": "unknown", "title": None, "due": None, "precision": None}


@pytest.mark.parametrize(
    ("routed", "status", "check"),
    [
        ({"connector": "calc", "command": "calc.evaluate", "matches": [CALC_MATCH]}, "agreed", None),
        (
            {"connector": "tasks", "command": "task.create", "matches": [ROUTED_CREATE["matches"][0], {**CALC_MATCH, "confidence": 0.45}]},
            "disputed",
            "приложение: коннектор=tasks",
        ),
        ({"connector": None, "command": None, "matches": []}, "disputed", "приложение: коннектор=никто, intent=unknown"),
    ],
)
def test_other_connector_compares_route_and_command_id(project: Path, routed: dict[str, Any], status: str, check: str | None) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, ["сколько будет 2+2*2"], connector="calc")
    run(config, store, CALC, FakeRouter({"сколько будет 2+2*2": {**routed, "parse": UNKNOWN_PARSE}}))
    row = store.rows[0]
    assert row["status"] == status
    assert row.get("check") == check
    if status == "agreed":
        line = pipeline.corpus_line(row, pipeline.catalog_for(config).connector("calc"))
        assert line["connector"] == "calc" and line["intent"] == "calc.evaluate"


def test_unknown_label_means_no_own_match(project: Path) -> None:
    """Как в scenario_corpus_test.dart: у «unknown» маршрут не проверяется, своего совпадения нет."""
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    text = "привет, добавь задачу купить хлеб"
    add_rows(config, store, [text], connector="talk")
    unknown = {"intent": "unknown", "confident": True, "comment": ""}
    run(config, store, unknown, FakeRouter({text: ROUTED_CREATE}))
    assert store.rows[0]["status"] == "agreed"
    talk_match = {"connector": "talk", "command": "talk.greet", "confidence": 0.6, "implicit": False, "fallback": True}
    store.rows[0].update(status="new", labels={})
    store.rows[0].pop("final")
    run(config, store, unknown, FakeRouter({text: {**ROUTED_CREATE, "matches": [*ROUTED_CREATE["matches"], talk_match]}}))
    assert store.rows[0]["status"] == "disputed"
    assert store.rows[0]["check"] == "приложение: intent=talk.greet"


def test_dart_failure_leaves_rows_disputed_with_note(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    counts = run(config, store, LABEL_CREATE, FakeRouter(error=RuntimeError("dart run завершился с кодом 1:\nошибка компиляции")))
    row = CandidateStore(config.work_dir).rows[0]
    assert row["status"] == "disputed" and "final" not in row
    assert row["check"].startswith("проверка приложением не удалась: dart run завершился с кодом 1: ошибка")
    assert counts[pipeline.CHECK_FAILED] == 1 and counts["disputed"] == 1


def test_missing_dart_binary_does_not_crash(project: Path) -> None:
    config = dataclasses.replace(config_for(project), dart=str(project / "нет-dart"))
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    pipeline.label(config, store, LABELERS, factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)))
    assert store.rows[0]["status"] == "disputed"
    assert "не удалась" in store.rows[0]["check"]


def test_missing_result_and_garbage_are_disputed(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT, "Добавь задачу «Спорт» завтра"])
    run(config, store, LABEL_CREATE, FakeRouter({TASK_TEXT: {"connector": "tasks"}}))
    assert [r["status"] for r in store.rows] == ["disputed", "disputed"]
    assert "непонятный ответ" in store.rows[0]["check"]
    assert "нет результата" in store.rows[1]["check"]


def test_existing_single_label_disputed_rows_are_redecided(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    texts = ["Добавь задачу «А» завтра", "Добавь задачу «Б» завтра", "Добавь задачу «В» завтра", "Добавь задачу «Г» завтра"]
    add_rows(config, store, texts)
    statuses = ["disputed", "accepted", "rejected", "promoted"]
    for row, status in zip(store.rows, statuses):
        row["status"] = status
        row["labels"] = {"gemma": {**LABEL_CREATE, "title": row["text"][15]}}
    store.rows[1]["final"], store.rows[1]["final_by"] = {"intent": "listTasks"}, ["gemma", "manual"]
    store.save()
    answers = {t: {**ROUTED_CREATE, "parse": {**ROUTED_CREATE["parse"], "title": t[15]}} for t in texts}
    router = FakeRouter(answers)
    counts = pipeline.label(config, store, LABELERS, factory=no_models, router=router)
    assert router.calls == [[texts[0]]]
    rows = CandidateStore(config.work_dir).rows
    assert [r["status"] for r in rows] == ["agreed", "accepted", "rejected", "promoted"]
    assert rows[0]["final_by"] == ["gemma", "parser"]
    assert rows[1]["final"] == {"intent": "listTasks"}
    assert counts[pipeline.RECHECKED] == 1 and counts[pipeline.AGREED_BY_PARSER] == 1
    # --limit не мешает перепроверке: моделям нечего делать, она бесплатна.
    store.rows[0].update(status="disputed")
    store.rows[0].pop("final")
    router = FakeRouter({})
    pipeline.label(config, store, LABELERS, factory=no_models, router=router, limit=0)
    assert router.calls == [[texts[0]]]


def test_two_label_disputed_rows_are_not_redecided(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, [TASK_TEXT], "web")  # семейство manual:web — оба разметчика
    store.rows[0]["status"] = "disputed"
    store.rows[0]["labels"] = {"ollama": dict(LABEL_CREATE), "gemma": {**LABEL_CREATE, "due": "2026-11-04"}}
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    assert not pipeline.label(config, store, LABELERS, factory=no_models, router=router)
    assert not router.calls and store.rows[0]["status"] == "disputed"


def test_setting_off_keeps_old_behaviour(project: Path) -> None:
    path = project / "tools" / "corpus_gen" / "config.toml"
    path.write_text(path.read_text(encoding="utf-8").replace("[settings]", "[settings]\nsingle_labeler_check = false"), encoding="utf-8")
    config = config_for(project)
    assert config.single_labeler_check is False
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    counts = run(config, store, LABEL_CREATE, router)
    assert counts == {"disputed": 1}
    assert not router.calls and "check" not in store.rows[0]
    # Старые спорные тоже не перепроверяются.
    assert not pipeline.label(config, store, LABELERS, factory=no_models, router=router)


def test_bad_setting_value_is_rejected(project: Path) -> None:
    path = project / "tools" / "corpus_gen" / "config.toml"
    path.write_text(path.read_text(encoding="utf-8").replace("[settings]", '[settings]\nsingle_labeler_check = "да"'), encoding="utf-8")
    with pytest.raises(ValueError, match="single_labeler_check"):
        config_for(project)


def test_two_labelers_never_use_app_check(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, [TASK_TEXT], "web")
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    answers = {"ollama": LABEL_CREATE, "gemma": {**LABEL_CREATE, "due": "2026-11-04"}}
    pipeline.label(config, store, LABELERS, factory=lambda s: FakeProvider(s, label_responder(answers[s.name])), router=router)
    assert not router.calls
    assert store.rows[0]["status"] == "disputed" and "check" not in store.rows[0]
    store.rows[0].update(status="new", labels={})
    pipeline.label(config, store, LABELERS, factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)), router=router)
    assert store.rows[0]["status"] == "agreed"
    assert store.rows[0]["final_by"] == ["gemma", "ollama"]
    assert not router.calls


def test_relabel_drops_check_note(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    run(config, store, LABEL_CREATE, FakeRouter(error=RuntimeError("нет dart")))
    pipeline.relabel(store)
    assert "check" not in store.rows[0]


def test_cli_summary_and_review_show_check(project: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    summary = cli._label_summary(
        pipeline.Counter({"agreed": 5, "disputed": 2, pipeline.AGREED_BY_PARSER: 3, pipeline.RECHECKED: 4})
    )
    assert summary == (
        "Итог разметки: agreed=5, disputed=2; из них agreed (по парсеру)=3, "
        "перепроверено спорных с одной разметкой=4"
    )
    assert cli._label_summary(pipeline.Counter()) == "Итог разметки: нечего размечать"

    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    parse = {**ROUTED_CREATE["parse"], "due": None, "precision": None}
    run(config, store, LABEL_CREATE, FakeRouter({TASK_TEXT: {**ROUTED_CREATE, "parse": parse}}))
    monkeypatch.setattr("sys.stdin", io.StringIO("q\n"))
    assert cli.main(["--config", str(project / "tools" / "corpus_gen" / "config.toml"), "review"]) == 0
    assert "проверка: приложение: due=None" in capsys.readouterr().out


def test_app_agreed_rows_promote_as_active(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    run(config, store, LABEL_CREATE, FakeRouter({TASK_TEXT: ROUTED_CREATE}))

    assert pipeline.promote(config, store, router=FakeRouter({TASK_TEXT: ROUTED_CREATE})) == {"active": 1}


# --------------------------------------------- регрессии ревью: учитываются сохранённые разметки


ALPHA = make_source("alpha", "fa")
BETA = make_source("beta", "fb")


def test_disputed_row_with_two_stored_labels_is_not_redecided_when_one_labeler_left(project: Path) -> None:
    # alpha и beta разошлись в due; в этом запуске beta недоступна (--source alpha).
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    row = store.rows[0]
    row["status"] = "disputed"
    row["labels"] = {"alpha": dict(LABEL_CREATE), "beta": {**LABEL_CREATE, "due": "2026-11-05"}}
    store.save()
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    counts = pipeline.label(config, store, [ALPHA], factory=no_models, router=router)
    assert not router.calls and not counts
    row = CandidateStore(config.work_dir).rows[0]
    assert row["status"] == "disputed" and "final" not in row and "final_by" not in row


def test_manual_row_disputed_by_two_models_stays_disputed_with_one_source(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, [TASK_TEXT], "kimi-web")  # семейство manual:kimi-web
    row = store.rows[0]
    row["status"] = "disputed"
    row["labels"] = {"gemma": dict(LABEL_CREATE), "ollama": {**LABEL_CREATE, "title": "Хлеб"}}
    store.save()
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    pipeline.label(config, store, [GEMMA], factory=no_models, router=router)
    assert not router.calls
    assert store.rows[0]["status"] == "disputed" and "final_by" not in store.rows[0]


def test_new_label_beside_stored_label_of_unavailable_source_is_not_app_checked(project: Path) -> None:
    # beta разметила раньше, alpha тогда упала (error); теперь доступна только alpha.
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    row = store.rows[0]
    row["status"] = "error"
    row["labels"] = {"beta": {**LABEL_CREATE, "due": "2026-11-05"}}
    store.save()
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    pipeline.label(
        config, store, [ALPHA], factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)), router=router
    )
    row = store.rows[0]
    assert set(row["labels"]) == {"alpha", "beta"}
    assert not router.calls
    assert row["status"] == "disputed" and "final_by" not in row
    assert "beta" in row["check"]


def test_recheck_with_unknown_connector_leaves_row_disputed(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    row = store.rows[0]
    row.update(status="disputed", connector="gone", check="разметчик не уверен — с приложением не сверялось")
    row["labels"] = {"gemma": {**LABEL_CREATE, "confident": False}}
    store.save()
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE})
    for _ in range(2):
        counts = pipeline.label(config, store, LABELERS, factory=no_models, router=router)
    assert not counts and not router.calls
    row = CandidateStore(config.work_dir).rows[0]
    assert row["status"] == "disputed"
    assert not row.get("errors")
    assert row["check"] == "разметчик не уверен — с приложением не сверялось"


def test_tasks_label_claimed_by_corpus_warehouse_is_disputed(project: Path) -> None:
    # tool/route_phrases.dart видит и учебный склад корпусного теста: если фразу забирает он,
    # строка tasks упала бы в test/scenario_corpus_test.dart — значит, не agreed.
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT])
    routed = {
        **ROUTED_CREATE,
        "connector": "warehouse",
        "command": "warehouse.where",
        "matches": [
            {"connector": "tasks", "command": "task.create", "confidence": 0.75, "implicit": True, "fallback": False},
            {"connector": "warehouse", "command": "warehouse.where", "confidence": 0.6, "implicit": False, "fallback": False},
        ],
    }
    run(config, store, LABEL_CREATE, FakeRouter({TASK_TEXT: routed}))
    assert store.rows[0]["status"] == "disputed"
    assert store.rows[0]["check"] == "приложение: коннектор=warehouse"


def test_app_error_for_one_phrase_fails_only_that_phrase(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, [TASK_TEXT, "«сломанная»"])
    router = FakeRouter({TASK_TEXT: ROUTED_CREATE, "«сломанная»": {"error": "Bad state: No element"}})
    counts = run(config, store, LABEL_CREATE, router)
    good, broken = CandidateStore(config.work_dir).rows
    assert good["status"] == "agreed"
    assert broken["status"] == "disputed"
    assert broken["check"].startswith("проверка приложением не удалась: приложение упало на фразе")
    assert "Bad state" in broken["check"]
    assert counts[pipeline.CHECK_FAILED] == 1
