"""Темы генерации и намерения коннекторов: загружаются из topics/*.toml.

Каждый файл описывает один коннектор помощника (`tasks`, `warehouse`…): его id, допустимые
намерения разметки, какие из них несут название и срок, и темы генерации. Формат —
tools/corpus_gen/README.md, раздел «Темы и коннекторы».
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Коннектор по умолчанию: строки корпуса без ключа "connector" относятся к нему.
DEFAULT_CONNECTOR = "tasks"
DEFAULT_TOPICS_DIR = Path(__file__).resolve().parent.parent / "topics"

_ID = re.compile(r"^[a-z][a-z0-9_-]*$")
# Для tasks — имена CommandIntent (createTask), для других коннекторов — commandId из
# ConnectorMatch (warehouse.locate): scenario_corpus_test.dart сравнивает intent именно с ним.
_INTENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$")


@dataclass(frozen=True)
class Topic:
    name: str
    description: str
    # Намерения, из строк корпуса с которыми берутся примеры; None — все строки коннектора.
    intents: frozenset[str] | None = None


@dataclass(frozen=True)
class ConnectorTopics:
    id: str
    title: str
    description: str
    intents: tuple[str, ...]
    title_intents: frozenset[str]
    due_intents: frozenset[str]
    topics: dict[str, Topic]
    # Дополнительные правила для промпта генерации; для tasks — встроенные (prompts.py).
    generation_rules: str = ""
    # Спецификация разметки; для tasks — встроенная prompts.LABEL_SYSTEM.
    label_rules: str = ""
    path: Path | None = None

    def topic(self, name: str) -> Topic:
        try:
            return self.topics[name]
        except KeyError:
            raise ValueError(
                f"у коннектора «{self.id}» нет темы «{name}»; доступны: {', '.join(self.topics)}"
            ) from None


@dataclass(frozen=True)
class Catalog:
    connectors: dict[str, ConnectorTopics] = field(default_factory=dict)

    def connector(self, connector_id: str) -> ConnectorTopics:
        try:
            return self.connectors[connector_id]
        except KeyError:
            known = ", ".join(self.connectors) or "нет"
            raise ValueError(f"неизвестный коннектор «{connector_id}»; описаны: {known}") from None

    def resolve(self, ref: str) -> tuple[ConnectorTopics, Topic]:
        """«connector:topic» или просто «topic» — тема коннектора tasks."""
        connector_id, topic = split_ref(ref)
        connector = self.connector(connector_id)
        return connector, connector.topic(topic)

    def refs(self) -> list[str]:
        """Все темы в виде, который принимает --topic."""
        result = []
        for connector in self.connectors.values():
            for name in connector.topics:
                result.append(name if connector.id == DEFAULT_CONNECTOR else f"{connector.id}:{name}")
        return result


def split_ref(ref: str) -> tuple[str, str]:
    connector_id, sep, topic = ref.strip().partition(":")
    if not sep:
        return DEFAULT_CONNECTOR, connector_id
    return connector_id.strip(), topic.strip()


def row_connector(row: dict[str, Any]) -> str:
    """Коннектор кандидата или строки корпуса; старые записи без ключа — tasks."""
    return row.get("connector") or DEFAULT_CONNECTOR


def load_catalog(directory: Path | None = None) -> Catalog:
    directory = directory or DEFAULT_TOPICS_DIR
    files = sorted(directory.glob("*.toml")) if directory.is_dir() else []
    if not files:
        raise ValueError(f"в {directory} нет файлов тем *.toml")
    connectors: dict[str, ConnectorTopics] = {}
    for path in files:
        connector = load_connector(path)
        if connector.id in connectors:
            other = connectors[connector.id].path
            raise ValueError(f"{path}: коннектор «{connector.id}» уже описан в {other}")
        connectors[connector.id] = connector
    if DEFAULT_CONNECTOR not in connectors:
        raise ValueError(f"в {directory} нет файла с connector = \"{DEFAULT_CONNECTOR}\"")
    return Catalog(connectors)


def load_connector(path: Path) -> ConnectorTopics:
    try:
        with path.open("rb") as handle:
            raw = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"{path}: {error}") from None
    return parse_connector(raw, path)


def parse_connector(raw: dict[str, Any], path: Path | None = None) -> ConnectorTopics:
    where = str(path) if path else "темы"

    def fail(message: str) -> ValueError:
        return ValueError(f"{where}: {message}")

    connector_id = raw.get("connector")
    if not isinstance(connector_id, str) or not _ID.match(connector_id):
        raise fail("connector должен быть id из строчных латинских букв, цифр, - и _")
    intents = _strings(raw.get("intents"), "intents", fail)
    if not intents:
        raise fail("intents не может быть пустым")
    bad = [i for i in intents if not _INTENT.match(i)]
    if bad or len(set(intents)) != len(intents):
        raise fail(f"intents должны быть уникальными идентификаторами: {intents}")
    if "unknown" not in intents:
        raise fail("в intents должен быть «unknown» — для фраз не про этот коннектор")
    title_intents = _subset(raw.get("title_intents", []), "title_intents", intents, fail)
    due_intents = _subset(raw.get("due_intents", []), "due_intents", intents, fail)
    if connector_id != DEFAULT_CONNECTOR and (title_intents or due_intents):
        # Корпус проверяет у других коннекторов только маршрутизацию и commandId;
        # непустые title/due в их строках scenario_corpus_test.dart отвергает.
        raise fail("title_intents и due_intents бывают только у коннектора tasks")

    raw_topics = raw.get("topics")
    if not isinstance(raw_topics, dict) or not raw_topics:
        raise fail("нужна хотя бы одна тема [topics.<имя>]")
    topics: dict[str, Topic] = {}
    for name, item in raw_topics.items():
        if not _ID.match(name):
            raise fail(f"имя темы «{name}» должно быть из строчных латинских букв, цифр, - и _")
        if not isinstance(item, dict):
            raise fail(f"тема «{name}» должна быть таблицей [topics.{name}]")
        description = item.get("description")
        if not isinstance(description, str) or not description.strip():
            raise fail(f"у темы «{name}» нет description")
        topic_intents = None
        if "intents" in item:
            topic_intents = _subset(item["intents"], f"topics.{name}.intents", intents, fail)
            if not topic_intents:
                raise fail(f"topics.{name}.intents пуст — уберите ключ, чтобы брать все примеры")
        topics[name] = Topic(name=name, description=" ".join(description.split()), intents=topic_intents)

    label_rules = str(raw.get("label_rules") or "").strip()
    if connector_id != DEFAULT_CONNECTOR and not label_rules:
        raise fail("для коннектора нужна спецификация разметки label_rules")
    return ConnectorTopics(
        id=connector_id,
        title=str(raw.get("title") or connector_id),
        description=" ".join(str(raw.get("description") or "").split()),
        intents=tuple(intents),
        title_intents=title_intents,
        due_intents=due_intents,
        topics=topics,
        generation_rules=str(raw.get("generation_rules") or "").strip(),
        label_rules=label_rules,
        path=path,
    )


def _strings(value: Any, key: str, fail: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise fail(f"{key} должен быть списком строк")
    return list(value)


def _subset(value: Any, key: str, intents: list[str], fail: Any) -> frozenset[str]:
    items = _strings(value, key, fail)
    unknown = sorted(set(items) - set(intents))
    if unknown:
        raise fail(f"{key}: намерений {unknown} нет в intents")
    return frozenset(items)
