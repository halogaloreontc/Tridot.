"""Темы и намерения из topics/*.toml, коннектор в кандидатах и корпусе, правила названий."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from corpus_gen import cli, pipeline, prompts
from corpus_gen.providers import ProviderError
from corpus_gen.store import CandidateStore, read_jsonl
from corpus_gen.topics import DEFAULT_TOPICS_DIR, load_catalog, parse_connector, split_ref

from test_pipeline import LABEL_CREATE, FakeProvider, config_for, label_responder, make_source, project  # noqa: F401

WAREHOUSE_TOML = '''
connector = "warehouse"
title = "Склад"
description = "поиск товара по артикулу"
intents = ["whereIs", "stockQty", "unknown"]
title_intents = []
due_intents = []
generation_rules = "Артикул — 5–6 цифр."
label_rules = """whereIs — где лежит товар; stockQty — сколько осталось."""

[topics.where]
description = "где лежит товар по артикулу"
intents = ["whereIs"]
'''

LABEL_WHERE = {**LABEL_CREATE, "intent": "whereIs", "title": "64115", "due": "2026-11-03"}


def _topics_dir(project: Path, with_warehouse: bool = True) -> Path:
    directory = project / "tools" / "corpus_gen" / "topics"
    directory.mkdir(exist_ok=True)
    (directory / "tasks.toml").write_text((DEFAULT_TOPICS_DIR / "tasks.toml").read_text(encoding="utf-8"), encoding="utf-8")
    if with_warehouse:
        (directory / "warehouse.toml").write_text(WAREHOUSE_TOML, encoding="utf-8")
    config_path = project / "tools" / "corpus_gen" / "config.toml"
    text = config_path.read_text(encoding="utf-8")
    if "topics_dir" not in text:
        config_path.write_text(text.replace('project_root = "../.."', 'project_root = "../.."\ntopics_dir = "topics"'), encoding="utf-8")
    return directory


def test_builtin_tasks_topics_load() -> None:
    catalog = load_catalog()
    tasks = catalog.connector("tasks")
    assert set(tasks.topics) == {"create", "reschedule", "complete", "list", "unknown", "tricky", "gaps"}
    assert tasks.intents == ("createTask", "listTasks", "completeTask", "rescheduleTask", "unknown")
    assert tasks.topics["create"].intents == {"createTask"}
    assert tasks.topics["tricky"].intents is None
    assert tasks.title_intents == {"createTask", "rescheduleTask", "completeTask"}
    assert tasks.due_intents == {"createTask", "rescheduleTask"}
    # Описания склеены в одну строку и просят фраз без кавычек.
    assert "\n" not in tasks.topics["create"].description
    assert "БЕЗ кавычек" in tasks.topics["create"].description


def test_topic_refs_accept_plain_and_connector_names(project: Path) -> None:
    catalog = load_catalog(_topics_dir(project))
    assert split_ref("create") == ("tasks", "create")
    assert split_ref("warehouse:where") == ("warehouse", "where")
    assert catalog.resolve("create")[0].id == "tasks"
    assert catalog.resolve("tasks:create")[1].name == "create"
    connector, topic = catalog.resolve("warehouse:where")
    assert (connector.id, topic.intents) == ("warehouse", {"whereIs"})
    assert "warehouse:where" in catalog.refs() and "create" in catalog.refs()
    with pytest.raises(ValueError, match="нет темы"):
        catalog.resolve("where")
    with pytest.raises(ValueError, match="неизвестный коннектор"):
        catalog.resolve("expeora:create")


@pytest.mark.parametrize(
    ("patch", "message"),
    [
        ({"connector": "Склад"}, "connector"),
        ({"intents": ["whereIs"]}, "unknown"),
        ({"intents": ["whereIs", "whereIs", "unknown"]}, "уникальными"),
        ({"title_intents": ["createTask"]}, "title_intents"),
        ({"topics": {}}, "хотя бы одна тема"),
        ({"topics": {"where": {"description": " "}}}, "description"),
        ({"topics": {"where": {"description": "x", "intents": ["move"]}}}, "intents"),
        ({"label_rules": ""}, "label_rules"),
    ],
)
def test_invalid_topic_files_are_rejected(patch: dict[str, Any], message: str) -> None:
    import tomllib

    raw = {**tomllib.loads(WAREHOUSE_TOML), **patch}
    with pytest.raises(ValueError, match=message):
        parse_connector(raw)


def test_duplicate_connector_and_missing_tasks_are_rejected(tmp_path: Path) -> None:
    (tmp_path / "a.toml").write_text(WAREHOUSE_TOML, encoding="utf-8")
    with pytest.raises(ValueError, match="tasks"):
        load_catalog(tmp_path)
    (tmp_path / "b.toml").write_text(WAREHOUSE_TOML, encoding="utf-8")
    with pytest.raises(ValueError, match="уже описан"):
        load_catalog(tmp_path)
    with pytest.raises(ValueError, match="нет файлов"):
        load_catalog(tmp_path / "nope")


def test_generate_uses_connector_topic_and_examples(project: Path) -> None:
    _topics_dir(project)
    corpus = project / "test" / "corpus" / "warehouse.jsonl"
    corpus.write_text(
        json.dumps({"id": "w1", "connector": "warehouse", "text": "где лежит 64115", "intent": "whereIs"}, ensure_ascii=False)
        + "\n",
        encoding="utf-8",
    )
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    provider: list[FakeProvider] = []

    def factory(source: Any) -> FakeProvider:
        provider.append(FakeProvider(source, lambda *_: {"phrases": ["где 70012?"]}))
        return provider[0]

    report = pipeline.generate(config, store, "warehouse:where", 1, [make_source("gen", "g")], factory=factory)
    assert report.added == 1
    row = CandidateStore(config.work_dir).rows[0]
    assert (row["connector"], row["topic"]) == ("warehouse", "where")
    prompt = provider[0].calls[0]
    assert "где лежит 64115" in prompt and "Добавь задачу «Отчёт»" not in prompt
    assert "Артикул — 5–6 цифр." in prompt and "БОЛЬШИНСТВО" not in prompt


def test_tasks_generation_prompt_asks_for_mostly_unquoted_phrases(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    calls: list[FakeProvider] = []

    def factory(source: Any) -> FakeProvider:
        calls.append(FakeProvider(source, lambda *_: {"phrases": ["добавь позвонить маме завтра"]}))
        return calls[0]

    pipeline.generate(config, store, "create", 1, [make_source("gen", "g")], factory=factory)
    prompt = calls[0].calls[0]
    assert "БОЛЬШИНСТВО фраз — без кавычек" in prompt
    assert "Добавь задачу «Отчёт» завтра" in prompt  # пример из корпуса tasks
    assert store.rows[0]["connector"] == "tasks"


def test_label_system_title_rules() -> None:
    text = " ".join(prompts.LABEL_SYSTEM.split())
    assert "Кавычки НЕ обязательны" in text
    assert "Кавычек нет — title = остаток фразы" in text
    assert "#хештегов" in text and "пожалуйста" in text
    assert "«Купить завтрак»" in text and "«Обновить до версии 2.10»" in text
    assert "«Звонок клиенту»" in text
    assert "«Не забыть купить хлеб»" in text
    assert "unbalancedQuotes" in text and "multipleTitles" in text
    assert "Без кавычек — null" not in text  # старое правило снято


def test_label_system_and_schema_follow_connector(project: Path) -> None:
    catalog = load_catalog(_topics_dir(project))
    tasks, warehouse = catalog.connector("tasks"), catalog.connector("warehouse")
    assert prompts.label_system(tasks) is prompts.LABEL_SYSTEM
    system = prompts.label_system(warehouse)
    assert "whereIs, stockQty, unknown" in system and "сколько осталось" in system
    assert prompts.label_schema(warehouse)["properties"]["intent"]["enum"] == ["whereIs", "stockQty", "unknown"]
    assert "createTask" in prompts.label_schema(tasks)["properties"]["intent"]["enum"]


def test_normalize_label_keeps_unquoted_create_title() -> None:
    label = pipeline.normalize_label({**LABEL_CREATE, "title": "Позвонить клиенту", "due": "2026-11-03T10:00", "precision": "dateTime"})
    assert label["title"] == "Позвонить клиенту"
    assert pipeline.normalize_label({**LABEL_CREATE, "title": "«Купить хлеб»"})["title"] == "Купить хлеб"
    assert pipeline.normalize_label({**LABEL_CREATE, "title": "", "due": None})["title"] is None
    target = pipeline.normalize_label({**LABEL_CREATE, "intent": "completeTask", "title": "Отчёт"})
    assert (target["title"], target["due"]) == ("Отчёт", None)


def test_normalize_label_uses_connector_intents(project: Path) -> None:
    warehouse = load_catalog(_topics_dir(project)).connector("warehouse")
    label = pipeline.normalize_label(LABEL_WHERE, warehouse)
    assert (label["intent"], label["title"], label["due"]) == ("whereIs", None, None)
    with pytest.raises(ProviderError):
        pipeline.normalize_label(LABEL_CREATE, warehouse)
    with pytest.raises(ProviderError):
        pipeline.normalize_label(LABEL_WHERE)  # по умолчанию — намерения tasks


def test_connector_propagates_from_import_to_corpus(project: Path) -> None:
    _topics_dir(project)
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["где лежит 64115"], "web", "warehouse:manual")
    pipeline.import_manual(config, store, ["добавь позвонить клиенту завтра в 10"], "web")
    assert [r["connector"] for r in store.rows] == ["warehouse", "tasks"]
    with pytest.raises(ValueError, match="неизвестный коннектор"):
        pipeline.import_manual(config, store, ["x"], "web", "expeora:manual")

    labels = {"where": LABEL_WHERE, "task": {**LABEL_CREATE, "title": "Позвонить клиенту", "due": "2026-11-03T10:00", "precision": "dateTime"}}
    systems: list[str] = []

    class Recording(FakeProvider):
        def complete(self, system: str, user: str, schema: dict[str, Any]) -> Any:
            systems.append(system)
            assert ("whereIs" in schema["properties"]["intent"]["enum"]) == ("64115" in user)
            return super().complete(system, user, schema)

    respond = lambda _s, user: dict(labels["where"] if "64115" in user else labels["task"])  # noqa: E731
    pipeline.label(config, store, [make_source("l1", "x"), make_source("l2", "y")], factory=lambda s: Recording(s, respond))
    assert [r["status"] for r in store.rows] == ["agreed", "agreed"]
    assert any("коннектор «warehouse»" in s for s in systems)

    parsed_ids: list[str] = []

    def fake_parser(_config: Any, items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        parsed_ids.extend(i["text"] for i in items)
        return {i["cid"]: dict(i["final"]) for i in items}

    counts = pipeline.promote(config, store, parser=fake_parser)
    assert counts == {"active": 1, "unverified": 1}
    assert parsed_ids == ["добавь позвонить клиенту завтра в 10"]  # склад парсеру задач не отдаём
    where, task = read_jsonl(config.corpus_dir / pipeline.GENERATED_FILE)
    # Не known_gap: верно размеченная фраза уронила бы scenario_corpus_test.dart.
    assert where["connector"] == "warehouse" and "status" not in where
    assert where["intent"] == "whereIs" and "title" not in where and "due" not in where
    assert "connector" not in task
    assert (task["title"], task["due"]) == ("Позвонить клиенту", "2026-11-03T10:00")


def test_old_rows_without_connector_are_tasks(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Добавь задачу «Купить хлеб» завтра"], "web")
    del store.rows[0]["connector"]
    pipeline.label(config, store, [make_source("l1", "x"), make_source("l2", "y")], factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)))
    assert store.rows[0]["status"] == "agreed"
    assert "connector" not in pipeline.corpus_line(store.rows[0])


def test_unknown_connector_row_is_error_not_crash(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["где лежит 64115"], "web")
    store.rows[0]["connector"] = "gone"
    pipeline.label(config, store, [make_source("l1", "x"), make_source("l2", "y")], factory=lambda s: FakeProvider(s, label_responder(LABEL_CREATE)))
    assert store.rows[0]["status"] == "error"
    assert "gone" in store.rows[0]["errors"][0]


def test_cli_topics_and_bad_topic(project: Path, capsys: pytest.CaptureFixture[str]) -> None:
    _topics_dir(project)
    config_path = str(project / "tools" / "corpus_gen" / "config.toml")
    assert cli.main(["--config", config_path, "topics"]) == 0
    out = capsys.readouterr().out
    assert "warehouse:where" in out and "createTask" in out
    assert cli.main(["--config", config_path, "generate", "--topic", "warehouse:nope"]) == 2
    assert "нет темы" in capsys.readouterr().err


def test_readme_warehouse_example_is_valid_and_not_active() -> None:
    import re
    import tomllib

    readme = (Path(__file__).resolve().parent.parent / "README.md").read_text(encoding="utf-8")
    block = re.search(r'```toml\n(connector = "warehouse".*?)```', readme, re.S)
    assert block is not None
    connector = parse_connector(tomllib.loads(block.group(1)))
    assert connector.intents == (
        "warehouse.whereIs",
        "warehouse.stockQty",
        "warehouse.arrivals",
        "warehouse.noPhoto",
        "unknown",
    )
    assert not connector.title_intents and not connector.due_intents
    assert "warehouse" not in load_catalog().connectors


def test_connector_intents_may_be_dotted_command_ids() -> None:
    raw = tomllib_loads(WAREHOUSE_TOML.replace('["whereIs", "stockQty", "unknown"]', '["warehouse.locate", "unknown"]').replace('intents = ["whereIs"]', 'intents = ["warehouse.locate"]'))
    assert parse_connector(raw).intents == ("warehouse.locate", "unknown")
    for bad in ("warehouse.", ".locate", "warehouse..locate"):
        with pytest.raises(ValueError, match="уникальными идентификаторами"):
            parse_connector({**raw, "intents": [bad, "unknown"]})


@pytest.mark.parametrize("key", ["title_intents", "due_intents"])
def test_task_fields_are_only_for_tasks_connector(key: str) -> None:
    raw = tomllib_loads(WAREHOUSE_TOML)
    with pytest.raises(ValueError, match="только у коннектора tasks"):
        parse_connector({**raw, key: ["whereIs"]})


def test_non_tasks_corpus_line_has_no_task_fields() -> None:
    warehouse = parse_connector(tomllib_loads(WAREHOUSE_TOML))
    row = {
        "cid": "w1",
        "text": "что пришло завтра",
        "now": pipeline.CORPUS_DEFAULT_NOW,
        "source": "s",
        "topic": "where",
        "final_by": ["a"],
        "final": {"intent": "whereIs", "title": "x", "due": "2026-11-03", "precision": "date", "issue": "inPast", "titleIssue": "none"},
    }
    line = pipeline.corpus_line(row, warehouse)
    assert set(line) == {"id", "text", "connector", "intent", "source", "tags"}


def test_promote_compares_target_title_with_target_query(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, ["Перенеси звонок клиенту на завтра"], "web")
    row = store.rows[0]
    row["status"] = "accepted"
    row["final"] = {"intent": "rescheduleTask", "title": "Звонок клиенту", "due": "2026-11-03", "precision": "date", "issue": "none", "titleIssue": "none"}
    store.save()

    def fake_parser(_config: Any, items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        # Так отвечает tool/parse_phrases.dart: слова цели — в targetQuery, title пуст.
        return {i["cid"]: {**i["final"], "title": None, "targetQuery": "Звонок клиенту"} for i in items}

    assert pipeline.promote(config, store, parser=fake_parser) == {"active": 1}
    (line,) = read_jsonl(config.corpus_dir / pipeline.GENERATED_FILE)
    assert "status" not in line and line["title"] == "Звонок клиенту"


def test_parsed_field_title_for_create_ignores_target_query() -> None:
    parsed = {"intent": "createTask", "title": None, "targetQuery": "x"}
    assert pipeline.parsed_field(parsed, "title") is None
    quoted = {"intent": "completeTask", "title": "Отчёт", "targetQuery": None}
    assert pipeline.parsed_field(quoted, "title") == "Отчёт"


def test_label_system_knows_new_due_rules() -> None:
    assert "ambiguousHour" in prompts.ISSUES
    assert "ambiguousHour" in prompts.LABEL_SYSTEM
    assert "1.5 кг" in prompts.LABEL_SYSTEM


def test_label_system_knows_weekdays_and_relative_dues() -> None:
    text = " ".join(prompts.LABEL_SYSTEM.split())
    assert "в следующую пятницу" in text and "пн вт ср чт пт сб вс" in text
    assert "через полчаса" in text and "через пару дней" in text
    assert "«пятничный отчёт»" in text and "conflictingDays" in text


def tomllib_loads(text: str) -> dict[str, Any]:
    import tomllib

    return tomllib.loads(text)
