from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable

import pytest

from corpus_gen import pipeline, prompts
from corpus_gen.config import Source, load_config
from corpus_gen.providers import Completion, ProviderError, _load_json
from corpus_gen.store import CandidateStore, read_jsonl


def make_source(name: str, family: str, roles=("generate", "label"), price_out: float = 0.0) -> Source:
    return Source(
        name=name,
        kind="openai_compat",
        family=family,
        model="m",
        roles=frozenset(roles),
        base_url="http://x",
        price_out=price_out,
    )


class FakeProvider:
    def __init__(self, source: Source, respond: Callable[[str, str], dict[str, Any]]) -> None:
        self.source = source
        self.respond = respond
        self.calls: list[str] = []

    def complete(self, system: str, user: str, schema: dict[str, Any]) -> Completion:
        self.calls.append(user)
        return Completion(self.respond(system, user), input_tokens=100, output_tokens=50)


@pytest.fixture()
def project(tmp_path: Path) -> Path:
    corpus = tmp_path / "test" / "corpus"
    corpus.mkdir(parents=True)
    (corpus / "create.jsonl").write_text(
        json.dumps({"id": "c1", "text": "Добавь задачу «Отчёт» завтра", "intent": "createTask"}, ensure_ascii=False)
        + "\n",
        encoding="utf-8",
    )
    tool = tmp_path / "tools" / "corpus_gen"
    tool.mkdir(parents=True)
    (tool / "config.toml").write_text(
        """
[settings]
project_root = "../.."

[[source]]
name = "a"
kind = "openai_compat"
family = "fa"
base_url = "http://x"
model = "m"
""",
        encoding="utf-8",
    )
    return tmp_path


def config_for(project: Path):
    return load_config(project / "tools" / "corpus_gen" / "config.toml")


LABEL_CREATE = {
    "intent": "createTask",
    "title": "Купить хлеб",
    "due": "2026-11-03",
    "precision": "date",
    "issue": "none",
    "titleIssue": "none",
    "confident": True,
    "comment": "",
}


def label_responder(label: dict[str, Any]) -> Callable[[str, str], dict[str, Any]]:
    return lambda system, user: dict(label)


def test_generate_skips_duplicates_of_corpus_and_candidates(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    phrases = ["Добавь задачу «Отчёт» завтра", "добавь  задачу «отчет» ЗАВТРА", "Создай задачу «Хлеб»", "Создай задачу «Хлеб»"]
    source = make_source("gen", "g")
    report = pipeline.generate(
        config,
        store,
        "create",
        4,
        [source],
        factory=lambda s: FakeProvider(s, lambda *_: {"phrases": phrases}),
    )
    assert report.added == 1
    assert report.duplicates == 3
    assert [r["text"] for r in CandidateStore(config.work_dir).rows] == ["Создай задачу «Хлеб»"]
    assert read_jsonl(config.work_dir / "usage.jsonl")[0]["source"] == "gen"


def test_generate_reports_provider_failure(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)

    def boom(*_: Any) -> dict[str, Any]:
        raise ProviderError("лимит")

    report = pipeline.generate(config, store, "create", 5, [make_source("gen", "g")], factory=lambda s: FakeProvider(s, boom))
    assert report.added == 0
    assert report.errors and "лимит" in report.errors[0]


def test_choose_labelers_excludes_generator_family_and_duplicates() -> None:
    labelers = [
        make_source("same", "g", price_out=0.1),
        make_source("cheap", "x", price_out=0.2),
        make_source("cheap-twin", "x", price_out=0.3),
        make_source("other", "y", price_out=5.0),
    ]
    chosen = pipeline.choose_labelers({"family": "g"}, labelers)
    assert [s.name for s in chosen] == ["cheap", "other"]


def run_label(project: Path, first: dict[str, Any], second: dict[str, Any]) -> CandidateStore:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Добавь задачу «Купить хлеб» завтра"], "kimi-web")
    labelers = [make_source("l1", "x"), make_source("l2", "y")]
    answers = {"l1": first, "l2": second}
    pipeline.label(config, store, labelers, factory=lambda s: FakeProvider(s, label_responder(answers[s.name])))
    return CandidateStore(config.work_dir)


def test_label_agreement_sets_final(project: Path) -> None:
    store = run_label(project, LABEL_CREATE, {**LABEL_CREATE, "due": "2026-11-03", "comment": "ok"})
    row = store.rows[0]
    assert row["status"] == "agreed"
    assert row["final"]["title"] == "Купить хлеб"


def test_label_disagreement_goes_to_review(project: Path) -> None:
    store = run_label(project, LABEL_CREATE, {**LABEL_CREATE, "due": "2026-11-04"})
    assert store.rows[0]["status"] == "disputed"
    assert "final" not in store.rows[0]


def test_label_not_confident_goes_to_review(project: Path) -> None:
    store = run_label(project, LABEL_CREATE, {**LABEL_CREATE, "confident": False})
    assert store.rows[0]["status"] == "disputed"


def test_label_invalid_output_is_error_and_retried(project: Path) -> None:
    config = config_for(project)
    store = run_label(project, LABEL_CREATE, {**LABEL_CREATE, "intent": "delete"})
    assert store.rows[0]["status"] == "error"
    # Повторный запуск размечает только недостающее.
    calls: list[str] = []

    def factory(source: Source) -> FakeProvider:
        calls.append(source.name)
        return FakeProvider(source, label_responder(LABEL_CREATE))

    pipeline.label(config, store, [make_source("l1", "x"), make_source("l2", "y")], factory=factory)
    assert store.rows[0]["status"] == "agreed"
    assert set(store.rows[0]["labels"]) == {"l1", "l2"}


def test_normalize_label_cleans_fields() -> None:
    label = pipeline.normalize_label(
        {"intent": "listTasks", "title": "x", "due": "2026-11-03", "precision": "date", "issue": "none", "titleIssue": "none"}
    )
    assert label["title"] is None and label["due"] is None and label["precision"] is None
    timed = pipeline.normalize_label({**LABEL_CREATE, "due": "2026-11-03T10:00:00", "precision": "dateTime"})
    assert (timed["due"], timed["precision"]) == ("2026-11-03T10:00", "dateTime")
    with pytest.raises(ProviderError):
        pipeline.normalize_label({**LABEL_CREATE, "due": "завтра"})


def test_import_manual_strips_list_markers_but_keeps_quotes(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    report = pipeline.import_manual(config, store, ["1. «Позвонить» завтра", "- Заверши её", "", "• Заверши её"], "kimi-web")
    assert report.added == 2 and report.duplicates == 1
    assert [r["text"] for r in store.rows] == ["«Позвонить» завтра", "Заверши её"]
    assert store.rows[0]["family"] == "manual:kimi-web"


def tasks_route(parse: dict[str, Any], connector: str | None = "tasks") -> dict[str, Any]:
    """Ответ tool/route_phrases.dart: фразу забрал connector, parse — разбор ScenarioParser."""
    matches = [] if connector is None else [
        {"connector": connector, "command": "task.create", "confidence": 0.9, "implicit": False, "fallback": False}
    ]
    return {"connector": connector, "command": matches[0]["command"] if matches else None, "matches": matches, "parse": parse}


def test_promote_marks_parser_mismatch_as_known_gap(project: Path) -> None:
    config = config_for(project)
    store = run_label(project, LABEL_CREATE, LABEL_CREATE)
    pipeline.import_manual(config, store, ["Добавь задачу «Спорт» в понедельник"], "kimi-web")
    gap = store.rows[1]
    gap["status"] = "accepted"
    gap["final"] = {**{k: LABEL_CREATE.get(k) for k in prompts.LABEL_FIELDS}, "title": "Спорт", "due": "2026-11-09"}
    store.save()

    def fake_router(_config: Any, items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        results = {}
        for item in items:
            final = dict(item["final"])
            if "понедельник" in item["text"]:
                final["due"], final["precision"] = None, None
            results[item["cid"]] = tasks_route(final)
        return results

    counts = pipeline.promote(config, store, router=fake_router)
    assert counts == {"active": 1, "known_gap": 1}
    lines = read_jsonl(config.corpus_dir / pipeline.GENERATED_FILE)
    assert "status" not in lines[0]
    assert lines[1]["status"] == "known_gap" and "due=None" in lines[1]["note"]
    assert all(l["id"].startswith("gen-") and l["source"] == "kimi-web" for l in lines)
    # Повторный перенос ничего не дублирует.
    assert pipeline.promote(config, CandidateStore(config.work_dir), router=fake_router) == {}


def test_corpus_line_omits_defaults() -> None:
    row = {
        "cid": "abc",
        "text": "Покажи задачи",
        "now": pipeline.CORPUS_DEFAULT_NOW,
        "source": "s",
        "topic": "list",
        "labels": {"a": {}, "b": {}, "stale": {}},
        "final_by": ["a", "b"],
        "final": {"intent": "listTasks", "title": None, "due": None, "precision": None, "issue": "none", "titleIssue": "none"},
    }
    assert pipeline.corpus_line(row) == {
        "id": "gen-abc",
        "text": "Покажи задачи",
        "intent": "listTasks",
        "source": "s",
        "tags": ["topic:list", "labels:a,b"],
    }


def test_corpus_line_and_tool_input_carry_after() -> None:
    """Контекст сессии `after` проходит насквозь: в строку корпуса и во вход route_phrases.dart."""
    row = {
        "cid": "ctx",
        "text": "сделай бэкап",
        "now": pipeline.CORPUS_DEFAULT_NOW,
        "after": "passwords",
        "source": "manual",
        "topic": "context",
        "final": {"intent": "passwords.backup"},
    }
    connector = pipeline.load_catalog().connector("passwords")
    line = pipeline.corpus_line(row, connector)
    assert line["after"] == "passwords"
    assert list(line)[:5] == ["id", "text", "connector", "intent", "after"]
    assert pipeline._tool_input(row) == {
        "id": "ctx",
        "text": "сделай бэкап",
        "now": pipeline.CORPUS_DEFAULT_NOW,
        "after": "passwords",
    }
    # Без контекста поля нет.
    del row["after"]
    assert "after" not in pipeline.corpus_line(row, connector)
    assert "after" not in pipeline._tool_input(row)


def test_load_json_tolerates_fences_and_text() -> None:
    assert _load_json('```json\n{"a": 1}\n```', "x") == {"a": 1}
    assert _load_json('Вот ответ: {"a": 2} — готово', "x") == {"a": 2}
    with pytest.raises(ProviderError):
        _load_json("нет json", "x")


def test_source_availability(monkeypatch: pytest.MonkeyPatch) -> None:
    source = Source(name="k", kind="openai_compat", family="f", model="m", roles=frozenset({"label"}), base_url="u", api_key_env="K_KEY")
    monkeypatch.delenv("K_KEY", raising=False)
    assert "K_KEY" in (source.unavailable_reason() or "")
    monkeypatch.setenv("K_KEY", "secret")
    assert source.unavailable_reason() is None
    placeholder = Source(name="p", kind="openai_compat", family="f", model="<модель>", roles=frozenset({"label"}), base_url="u")
    assert "модель" in (placeholder.unavailable_reason() or "")


def test_example_config_loads() -> None:
    config = load_config(Path(__file__).resolve().parent.parent / "config.example.toml")
    names = {s.name for s in config.sources}
    assert {"ollama", "claude-haiku", "claude-sonnet", "kimi", "deepseek"} <= names
    assert config.corpus_dir.name == "corpus"
