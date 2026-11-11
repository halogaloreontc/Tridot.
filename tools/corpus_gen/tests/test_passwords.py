"""Темы навыка «Пароли» (topics/passwords.toml) и фильтр секретов (corpus_gen/secret_filter.py).

Настоящих паролей здесь нет: похожие на секрет строки собраны из маркера CANARY, и тесты
проверяют, что такие фразы отбрасываются и нигде не печатаются.
"""

from __future__ import annotations

import dataclasses
import json
import os
import re
import shutil
from pathlib import Path
from typing import Any

import pytest

from corpus_gen import cli, pipeline, prompts, providers, secret_filter
from corpus_gen.secret_filter import drop_secrets, looks_secret
from corpus_gen.store import CandidateStore, read_jsonl
from corpus_gen.topics import load_catalog

from test_pipeline import FakeProvider, config_for, make_source, project  # noqa: F401
from test_single_labeler import GEMMA, LABELERS, FakeRouter, add_rows, no_models

REPO = Path(__file__).resolve().parents[3]
PHRASES_DART = REPO / "lib" / "core" / "skills" / "passwords" / "passwords_phrases.dart"

FIXTURES = Path(__file__).resolve().parent / "fixtures"

# Цифровые «коды» тоже маркеры: последовательность 0123…, а не похожий на настоящий PIN.
CANARY_PIN = "0123"
CANARY_PHONE = "+0 (000) 000-00-00"

# Похожие на секрет фразы. CANARY — маркер вместо пароля: настоящих секретов в тестах нет.
SECRET_LIKE = [
    "пароль от почты: CANARY",
    "мой пароль = CANARY",
    "пин-код: CANARY",
    "код домофона: CANARY",
    "логин CANARY пароль CANARY",
    "пароль от wifi это CANARY",
    "пароль от wifi «CANARY»",
    'запомни пароль "CANARY"',
    "пароль от почты CANARY-7x",
    "сохрани пароль CANARY_x9",
    "пароль от роутера canary2026",
    f"пароль от подъезда {CANARY_PIN}",
    f"пин от карты {CANARY_PIN}",
    "логин от почты canary@example.invalid",
    f"запомни пароль, мой телефон {CANARY_PHONE}",
    "Kx9!CANARY пароль от почты",
    # Смешанный регистр, длинное название сервиса, коды через пробелы, короткие и латинские.
    "пароль от почты CanaryCanary",
    "пароль от рабочей почты на ноутбуке это CanaryCanary",
    "пароль от рабочей почты на ноутбуке это canary",
    "пароль от wifi CANARYx",
    "пин 01 23",
    "код домофона 01 23",
    "wifi пароль 0 1 2 3",
    "пин от карты 012",
    "пароль от wifi c4n4r",
    "мой пароль canary, запомни",
    "пароль — это canary",
]

# Обычные фразы навыка и рядом с ним — остаются.
NORMAL = [
    "забыл пароль от почты",
    "Не помню пароль от Госуслуг!",
    "покажи пароль от wi-fi",
    "скопируй мой пароль от вк",
    "сгенерируй пароль на 24 символа без символов",
    "пароль из 5 слов",
    "какой у меня логин от госуслуг",
    "забыл мастер-пароль",
    "сделай резервную копию паролей",
    "напомни завтра в 10:00 сменить пароль от почты",
    "добавь задачу сменить пароль #дом",
    "сколько будет 6 паролей на 2",
    "Лиорио, пароль от Т-Банка?",
    "потерял телефон",
    "сгенерируй пароль на 128 символов",
    "сгенерируй 3 пароля по 16 символов",
    "пароль — это важно",
    "забыл пароль от iPhone",
    "покажи пароль от WhatsApp",
    "дай пароль от wifi гостям",
    "пароль wifi",
    "напомни сменить пароль через 2 дня",
]


def _fixture(name: str) -> list[str]:
    lines = (FIXTURES / name).read_text(encoding="utf-8").splitlines()
    return [line for line in lines if line.strip() and not line.startswith("#")]


def test_passwords_topics_load() -> None:
    catalog = load_catalog()
    passwords = catalog.connector("passwords")
    assert passwords.title == "Пароли"
    assert set(passwords.topics) == {
        "hint",
        "reveal_copy",
        "login",
        "manage",
        "generate_check",
        "backup_import",
        "lost",
        "tricky",
    }
    assert passwords.topics["tricky"].intents is None
    assert not passwords.title_intents and not passwords.due_intents
    assert "passwords:hint" in catalog.refs() and "passwords:tricky" in catalog.refs()
    # Правила разметки отдают задачам и чужим просьбам «unknown».
    rules = " ".join(passwords.label_rules.split())
    assert "«напомни сменить пароль»" in rules and "«поставить пароль на wifi»" in rules
    assert "«скажи Пете пароль от wifi»" in rules
    # Генераторам — запрет на секреты.
    assert "НЕТ самого пароля" in passwords.generation_rules


def _dart_command_ids() -> list[str]:
    """PasswordCommands.all в порядке объявления: commandId, которые возвращает PasswordsConnector."""
    source = PHRASES_DART.read_text(encoding="utf-8")
    body = re.search(r"abstract final class PasswordCommands \{(.*?)\n\}", source, re.S).group(1)
    constants = dict(re.findall(r"static const String (\w+) = '([^']+)';", body))
    names = re.search(r"static const List<String> all = <String>\[(.*?)\];", body, re.S).group(1)
    return [constants[name] for name in re.findall(r"\w+", names)]


def test_passwords_intents_are_exactly_command_ids() -> None:
    # Обратная сверка — test/tool/route_phrases_test.dart читает этот же файл тем.
    commands = _dart_command_ids()
    assert len(commands) == 20 and commands[0] == "passwords.hint"
    assert load_catalog().connector("passwords").intents == tuple(commands) + ("unknown",)


@pytest.mark.parametrize("text", SECRET_LIKE)
def test_secret_like_phrases_are_dropped(text: str) -> None:
    assert looks_secret(text, "passwords")
    # Со словом «пароль» фраза любого коннектора проверяется так же.
    if re.search(r"парол|пин|логин", text):
        assert looks_secret(text, "tasks")


@pytest.mark.parametrize("text", NORMAL)
def test_normal_phrases_are_kept(text: str) -> None:
    assert not looks_secret(text, "passwords")


def test_filter_is_not_weaker_than_secret_guard() -> None:
    # Те же фразы test/tool/route_phrases_test.dart проверяет настоящим SecretGuard.
    phrases = _fixture("secret_guard_positive.txt")
    assert len(phrases) >= 10 and all("CANARY" in p or "Canary" in p or "canary" in p for p in phrases)
    for text in phrases:
        assert secret_filter._guard_flags(text), text
        assert looks_secret(text, "passwords") and looks_secret(text, "tasks"), text


@pytest.mark.parametrize(
    "text",
    [
        f"напомни: код домофона {CANARY_PIN}",
        f"код от подъезда {CANARY_PIN} запиши в задачи",
        "p@ssword CANARY",
        "запомни пaроль canary1",  # латинская «a» в слове «пароль»
        "pаssword CANARY-x",  # кириллическая «а» в password
    ],
)
def test_codes_and_disguised_secret_words_in_other_connectors(text: str) -> None:
    assert secret_filter.mentions_secret(text)
    assert looks_secret(text, "tasks")


def test_quoted_task_titles_with_password_word_are_kept_for_tasks() -> None:
    # Кавычки у задач — название, а не пароль; у навыка «Пароли» кавычки по-прежнему запрещены.
    text = "добавь задачу «Сменить пароль от почты» на завтра"
    assert not looks_secret(text, "tasks")
    assert looks_secret(text, "passwords")
    assert looks_secret("пароль от wifi «CANARY»", "tasks")


def test_rule_examples_and_topic_descriptions_are_not_secret_like() -> None:
    # label_rules и описания тем уходят моделям: примеры в них сами проходят фильтр.
    passwords = load_catalog().connector("passwords")
    texts = [passwords.label_rules, *(t.description for t in passwords.topics.values())]
    examples = [e for text in texts for e in re.findall(r"«([^«»]+)»", text)]
    assert len(examples) > 50
    assert [e for e in examples if looks_secret(e, "passwords")] == []


def test_passwords_generation_prompt_has_no_permission_to_break_rules() -> None:
    catalog = load_catalog()
    passwords = catalog.connector("passwords")
    for topic in passwords.topics.values():
        prompt = prompts.generation_prompt(passwords, topic, 5, [])
        assert "нарушать правила" not in prompt
        assert "это правило нарушать нельзя" in prompt
    tasks = catalog.connector("tasks")
    assert "Часть фраз может нарушать правила" in prompts.generation_prompt(tasks, next(iter(tasks.topics.values())), 5, [])


@pytest.mark.parametrize(
    "broken",
    ['phrases: ["пароль от почты: CANARY"', '{"phrases": ["пароль от почты: CANARY",, "x"]}'],
)
def test_generation_errors_never_print_model_output(
    project: Path, capsys: pytest.CaptureFixture[str], broken: str
) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)

    class Broken:
        def __init__(self, source: Any) -> None:
            self.source = source

        def complete(self, *_args: Any) -> Any:
            providers._load_json(broken, self.source.name)

    report = pipeline.generate(config, store, "passwords:hint", 3, [make_source("gen", "g")], factory=Broken)
    assert report.errors and "ответ не JSON" in report.errors[0] and "скрыт" in report.errors[0]
    assert all("CANARY" not in e for e in report.errors)
    assert store.rows == []


def test_generation_errors_of_other_connectors_keep_harmless_snippets() -> None:
    error = providers.ProviderError("gen: ответ не JSON: 'купи хлеб'", snippet="купи хлеб")
    assert pipeline._generation_error(error, "tasks") == "gen: ответ не JSON: 'купи хлеб'"
    secret = providers.ProviderError("gen: ответ не JSON: 'пароль: CANARY'", snippet="пароль: CANARY")
    assert "CANARY" not in pipeline._generation_error(secret, "tasks")
    assert "CANARY" not in pipeline._generation_error(RuntimeError("пароль: CANARY"), "tasks")


def test_reject_secrets_keeps_human_accepted_rows_but_promote_skips_them(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, ["забыл пароль от почты"], "passwords")
    row = store.rows[0]
    row.update(
        text="пароль от почты: CANARY",
        status="accepted",
        final=dict(HINT_LABEL),
        labels={"gemma": dict(HINT_LABEL)},
    )
    assert pipeline.reject_secrets(store) == 1
    assert (row["status"], row["check"], row["labels"]) == ("accepted", pipeline.SECRET_CHECK, {"gemma": HINT_LABEL})
    assert pipeline.reject_secrets(store) == 0  # уже помечена
    assert pipeline.promote(config, store) == {}
    assert not (config.corpus_dir / pipeline.GENERATED_FILE).exists() or "CANARY" not in (
        config.corpus_dir / pipeline.GENERATED_FILE
    ).read_text(encoding="utf-8")


def test_other_connectors_without_secret_words_are_not_filtered() -> None:
    for text, connector in [("что в ячейке 215-1-1-1", "warehouse"), ("где лежит 64115", "warehouse"), ("сколько будет 1234*5678", "calc")]:
        assert not looks_secret(text, connector)
    # У навыка «Пароли» длинное число — уже код: такие фразы не генерируем.
    assert looks_secret("где лежит 64115", "passwords")
    kept, dropped = drop_secrets(NORMAL + SECRET_LIKE, "passwords")
    assert kept == NORMAL and dropped == len(SECRET_LIKE)


def test_generate_drops_secret_like_candidates_and_never_prints_them(project: Path, capsys: pytest.CaptureFixture[str]) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    # В примерах генератору тоже не уходит ничего похожего на секрет.
    (config.corpus_dir / "passwords.jsonl").write_text(
        "\n".join(
            json.dumps({"id": f"p{i}", "connector": "passwords", "text": t, "intent": "passwords.hint"}, ensure_ascii=False)
            for i, t in enumerate(["забыл пароль от почты", "пароль от подъезда CANARY-1"])
        )
        + "\n",
        encoding="utf-8",
    )
    prompts_seen: list[str] = []

    def respond(_system: str, user: str) -> dict[str, Any]:
        prompts_seen.append(user)
        return {"phrases": ["не помню пароль от озона", *SECRET_LIKE[:5]]}

    report = pipeline.generate(
        config, store, "passwords:hint", 6, [make_source("gen", "g")], factory=lambda s: FakeProvider(s, respond)
    )
    assert (report.added, report.secret_dropped) == (1, 5)
    assert [r["text"] for r in store.rows] == ["не помню пароль от озона"]
    assert "CANARY" not in prompts_seen[0] and "забыл пароль от почты" in prompts_seen[0]
    assert "CANARY" not in store.path.read_text(encoding="utf-8")
    cli._print_secret_dropped(report.secret_dropped)
    out = capsys.readouterr()
    assert "похожих на секрет" in out.out and "5" in out.out
    assert "CANARY" not in out.out + out.err


def test_import_manual_drops_secret_like_and_cli_prints_only_count(project: Path, capsys: pytest.CaptureFixture[str]) -> None:
    phrases = project / "phrases.txt"
    phrases.write_text("1. забыл логин от почты\n2. пароль от почты: CANARY\n- логин CANARY пароль CANARY\n", encoding="utf-8")
    config_path = str(project / "tools" / "corpus_gen" / "config.toml")
    assert cli.main(["--config", config_path, "import-manual", str(phrases), "--source", "web", "--topic", "passwords:manual"]) == 0
    out = capsys.readouterr()
    assert "Добавлено фраз: 1" in out.out and "похожих на секрет (пароль, код, логин, почта, телефон): 2" in out.out
    assert "CANARY" not in out.out + out.err
    store = CandidateStore(config_for(project).work_dir)
    assert [(r["text"], r["connector"]) for r in store.rows] == [("забыл логин от почты", "passwords")]


def test_label_rejects_secret_like_rows_without_calling_models(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, ["забыл пароль от почты"], "passwords")
    # Фразу вписали в work/candidates.jsonl руками, мимо фильтра.
    store.rows[0]["text"] = "пароль от почты: CANARY"
    counts = pipeline.label(config, store, LABELERS, factory=no_models, router=FakeRouter())
    assert counts[pipeline.SECRET_DROPPED] == 1
    row = store.rows[0]
    assert (row["status"], row["check"], row["labels"]) == ("rejected", pipeline.SECRET_CHECK, {})
    assert "CANARY" not in cli._label_summary(counts)


HINT_LABEL = {"intent": "passwords.hint", "confident": True, "comment": ""}


def _routed(connector: str | None, command: str | None, matches: list[tuple[str, str]]) -> dict[str, Any]:
    return {
        "connector": connector,
        "command": command,
        "matches": [{"connector": c, "command": m, "confidence": 0.92, "implicit": False, "fallback": False} for c, m in matches],
        "parse": {},
    }


def test_single_labeler_check_routes_passwords_phrases(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    texts = ["забыл пароль от почты", "покажи пароль от wifi", "скажи Пете пароль от wifi"]
    add_rows(config, store, texts, "passwords")
    labels = {
        "забыл пароль от почты": HINT_LABEL,
        "покажи пароль от wifi": HINT_LABEL,  # навык понял как reveal — расхождение
        "скажи Пете пароль от wifi": {"intent": "unknown", "confident": True, "comment": ""},
    }
    router = FakeRouter(
        {
            "забыл пароль от почты": _routed("passwords", "passwords.hint", [("passwords", "passwords.hint")]),
            "покажи пароль от wifi": _routed("passwords", "passwords.reveal", [("passwords", "passwords.reveal")]),
            "скажи Пете пароль от wifi": _routed(None, None, []),
        }
    )

    def respond(_system: str, user: str) -> dict[str, Any]:
        return dict(next(v for k, v in labels.items() if k in user))

    counts = pipeline.label(config, store, [GEMMA], factory=lambda s: FakeProvider(s, respond), router=router)
    assert counts[pipeline.AGREED_BY_PARSER] == 2
    by_text = {r["text"]: r for r in store.rows}
    assert by_text["забыл пароль от почты"]["status"] == "agreed"
    assert by_text["скажи Пете пароль от wifi"]["status"] == "agreed"
    assert by_text["покажи пароль от wifi"]["check"] == "приложение: intent=passwords.reveal"

    # promote: в generated.jsonl с "connector": "passwords" — корпусный тест включает навык.
    assert pipeline.promote(config, store) == {"unverified": 2}
    lines = read_jsonl(config.corpus_dir / pipeline.GENERATED_FILE)
    assert {line["connector"] for line in lines} == {"passwords"}
    assert {line["intent"] for line in lines} == {"passwords.hint", "unknown"}


def test_label_prompt_for_passwords_uses_command_ids() -> None:
    passwords = load_catalog().connector("passwords")
    assert prompts.label_schema(passwords)["properties"]["intent"]["enum"] == list(passwords.intents)
    assert "passwords.masterForgot" in prompts.label_system(passwords)


def _dart() -> str | None:
    return shutil.which("dart") or (
        "/opt/flutter/bin/dart" if Path("/opt/flutter/bin/dart").exists() else None
    )


@pytest.mark.skipif(
    os.environ.get("CORPUS_GEN_DART_TESTS") != "1" or _dart() is None,
    reason="настоящий dart: CORPUS_GEN_DART_TESTS=1 (долго — компиляция tool/route_phrases.dart)",
)
def test_real_router_routes_passwords_phrases(project: Path) -> None:
    config = dataclasses.replace(config_for(project), project_root=REPO, dart=_dart())
    items = [
        {"cid": "a", "text": "забыл пароль от почты", "now": pipeline.CORPUS_DEFAULT_NOW},
        {"cid": "b", "text": "склад, пароль от почты", "now": pipeline.CORPUS_DEFAULT_NOW},
        {"cid": "c", "text": "напомни завтра сменить пароль от почты", "now": pipeline.CORPUS_DEFAULT_NOW},
    ]
    results = pipeline.run_dart_router(config, items)
    assert (results["a"]["connector"], results["a"]["command"]) == ("passwords", "passwords.hint")
    assert results["b"]["connector"] == "passwords"
    assert "warehouse" not in {m["connector"] for m in results["b"]["matches"]}
    assert results["c"]["connector"] == "tasks"


def test_readme_describes_passwords_topics() -> None:
    readme = (Path(__file__).resolve().parent.parent / "README.md").read_text(encoding="utf-8")
    assert "topics/passwords.toml" in readme and "--topic passwords:hint" in readme
    assert "corpus_gen/secret_filter.py" in readme and "CANARY" in readme
    assert "tests/fixtures/secret_guard_positive.txt" in readme and "не слабее `SecretGuard`" in readme
    for topic in load_catalog().connector("passwords").topics:
        assert f"`passwords:{topic}`" in readme
