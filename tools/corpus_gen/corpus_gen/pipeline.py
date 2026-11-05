"""Конвейер: генерация → перекрёстная разметка → проверка человеком → перенос в корпус."""

from __future__ import annotations

import functools
import json
import re
import subprocess
import threading
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable

from . import prompts
from .config import Config, Source
from .topics import DEFAULT_CONNECTOR, Catalog, ConnectorTopics, load_catalog, row_connector, split_ref
from .providers import Provider, ProviderError, make_provider
from .store import CandidateStore, append_jsonl, candidate_id, clean_phrase, corpus_rows, normalize_text

ProviderFactory = Callable[[Source], Provider]
ParserRunner = Callable[[Config, list[dict[str, Any]]], dict[str, dict[str, Any]]]

GENERATED_FILE = "generated.jsonl"

# Значение «сейчас» по умолчанию в test/scenario_corpus_test.dart.
CORPUS_DEFAULT_NOW = "2026-11-02T16:30"



def catalog_for(config: Config) -> Catalog:
    """Темы и намерения коннекторов из topics/*.toml (settings.topics_dir в config.toml)."""
    return load_catalog(config.topics_dir)


@dataclass
class Report:
    added: int = 0
    duplicates: int = 0
    errors: list[str] | None = None

    def error(self, message: str) -> None:
        if self.errors is None:
            self.errors = []
        self.errors.append(message)


# ---------------------------------------------------------------- генерация


def generate(
    config: Config,
    store: CandidateStore,
    topic: str,
    count: int,
    sources: list[Source],
    *,
    per_request: int = 20,
    factory: ProviderFactory = make_provider,
    catalog: Catalog | None = None,
) -> Report:
    """topic — «connector:тема» или просто «тема» коннектора tasks."""
    catalog = catalog or catalog_for(config)
    connector, topic_ = catalog.resolve(topic)
    report = Report()
    known = _known_texts(config, store)
    examples = _examples(config, connector, topic_.intents)
    usage: list[dict[str, Any]] = []
    lock = threading.Lock()

    def run(source: Source) -> None:
        provider = factory(source)
        remaining = count
        while remaining > 0:
            size = min(per_request, remaining)
            remaining -= size
            try:
                completion = provider.complete(
                    prompts.GENERATION_SYSTEM,
                    prompts.generation_prompt(connector, topic_, size, examples),
                    prompts.GENERATION_SCHEMA,
                )
            except Exception as error:  # noqa: BLE001 — сеть, лимиты, отказ, не-JSON
                with lock:
                    report.error(f"{source.name}: {error}")
                    usage.append(_usage_row(source, "generate", error))
                return
            phrases = completion.data.get("phrases")
            with lock:
                usage.append(_usage_row(source, "generate", completion))
                if not isinstance(phrases, list):
                    report.error(f"{source.name}: в ответе нет списка phrases")
                    return
                for phrase in phrases:
                    if not isinstance(phrase, str) or not phrase.strip():
                        continue
                    if not _add_candidate(
                        store, known, phrase, source.name, source.family, connector.id, topic_.name, config
                    ):
                        report.duplicates += 1
                    else:
                        report.added += 1

    _run_parallel(sources, run)
    store.record_usage(usage)
    store.save()
    return report


def import_manual(
    config: Config,
    store: CandidateStore,
    lines: list[str],
    source_name: str,
    topic: str = "manual",
    *,
    catalog: Catalog | None = None,
) -> Report:
    """Фразы, вставленные из веб-чатов. Номера списков и маркеры срезаются, кавычки — нет.

    topic — «connector:тема» или «тема» (коннектор tasks); тема может быть любой меткой,
    например «manual», а коннектор должен быть описан в topics/*.toml.
    """
    connector_id, topic = split_ref(topic)
    (catalog or catalog_for(config)).connector(connector_id)
    report = Report()
    known = _known_texts(config, store)
    for raw in lines:
        phrase = re.sub(r"^\s*(?:\d+[.)]\s+|[-*•–—]\s+)", "", clean_phrase(raw)).strip()
        if not phrase:
            continue
        if _add_candidate(store, known, phrase, source_name, f"manual:{source_name}", connector_id, topic, config):
            report.added += 1
        else:
            report.duplicates += 1
    store.save()
    return report


def _add_candidate(
    store: CandidateStore,
    known: set[str],
    phrase: str,
    source: str,
    family: str,
    connector: str,
    topic: str,
    config: Config,
) -> bool:
    phrase = clean_phrase(phrase)
    key = normalize_text(phrase)
    if not key or key in known:
        return False
    known.add(key)
    store.rows.append(
        {
            "cid": candidate_id(phrase),
            "text": phrase,
            "now": config.default_now,
            "source": source,
            "family": family,
            "connector": connector,
            "topic": topic,
            "status": "new",
            "labels": {},
        }
    )
    return True


def _known_texts(config: Config, store: CandidateStore) -> set[str]:
    texts = {normalize_text(row["text"]) for row in corpus_rows(config.corpus_dir) if "text" in row}
    texts.update(normalize_text(row["text"]) for row in store.rows)
    return texts


def _examples(config: Config, connector: ConnectorTopics, intents: frozenset[str] | None) -> list[str]:
    rows = corpus_rows(config.corpus_dir)
    return [
        r["text"]
        for r in rows
        if r.get("text")
        and row_connector(r) == connector.id
        and (intents is None or r.get("intent") in intents)
    ]


# ----------------------------------------------------------------- разметка


def choose_labelers(candidate: dict[str, Any], labelers: list[Source], needed: int = 2) -> list[Source]:
    """Разметчики другого семейства, чем генератор, и разных семейств между собой; дешёвые первыми."""
    chosen: list[Source] = []
    families = {candidate.get("family")}
    for source in sorted(labelers, key=lambda s: (s.price_out, s.price_in, s.name)):
        if source.family in families:
            continue
        chosen.append(source)
        families.add(source.family)
        if len(chosen) == needed:
            break
    return chosen


def label(
    config: Config,
    store: CandidateStore,
    labelers: list[Source],
    *,
    limit: int | None = None,
    factory: ProviderFactory = make_provider,
    catalog: Catalog | None = None,
) -> Counter[str]:
    catalog = catalog or catalog_for(config)
    # Новые раньше упавших, чтобы --limit не застревал на одной ошибочной фразе;
    # фразы без подходящих разметчиков пропускаются.
    pending = [row for row in store.rows if row["status"] == "new"]
    pending += [row for row in store.rows if row["status"] == "error"]
    pending = [row for row in pending if choose_labelers(row, labelers)]
    if limit is not None:
        pending = pending[:limit]
    providers: dict[str, Provider] = {}
    semaphores = {s.name: threading.Semaphore(s.max_concurrency) for s in labelers}
    lock = threading.Lock()
    usage: list[dict[str, Any]] = []
    jobs: list[tuple[dict[str, Any], Source]] = []

    connectors: dict[str, ConnectorTopics] = {}
    for row in pending:
        try:
            connectors[row["cid"]] = catalog.connector(row_connector(row))
        except ValueError as error:
            row.setdefault("errors", []).append(str(error))
            continue
        for source in choose_labelers(row, labelers):
            if source.name not in row["labels"]:
                jobs.append((row, source))
            if source.name not in providers:
                providers[source.name] = factory(source)

    def run(job: tuple[dict[str, Any], Source]) -> None:
        row, source = job
        connector = connectors[row["cid"]]
        with semaphores[source.name]:
            try:
                completion = providers[source.name].complete(
                    prompts.label_system(connector),
                    prompts.label_prompt(row["text"], row["now"]),
                    prompts.label_schema(connector),
                )
            except Exception as error:  # noqa: BLE001
                with lock:
                    row.setdefault("errors", []).append(_error_text(source, error))
                    usage.append(_usage_row(source, "label", error))
                return
        with lock:
            usage.append(_usage_row(source, "label", completion))
            try:
                row["labels"][source.name] = normalize_label(completion.data, connector)
            except ProviderError as error:
                row.setdefault("errors", []).append(_error_text(source, error))

    workers = max(1, sum(s.max_concurrency for s in labelers))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(run, jobs))

    counts: Counter[str] = Counter()
    for row in pending:
        if row["cid"] not in connectors:
            row["status"] = "error"
        else:
            row["status"] = decide(row, choose_labelers(row, labelers))
        counts[row["status"]] += 1
    store.record_usage(usage)
    store.save()
    return counts


_OPENING_QUOTES = "«“„\""
_CLOSING_QUOTES = "»”“\""


def _error_text(source: Source, error: Exception) -> str:
    """Ошибки провайдера уже начинаются с имени источника — не дублируем его."""
    text = str(error)
    return text if text.startswith(f"{source.name}:") else f"{source.name}: {text}"


def _strip_title_quotes(title: Any) -> str | None:
    """Название — текст внутри кавычек; модели иногда захватывают и сами кавычки."""
    if not isinstance(title, str):
        return None
    title = title.strip()
    if len(title) >= 2 and title[0] in _OPENING_QUOTES and title[-1] in _CLOSING_QUOTES:
        title = title[1:-1].strip()
    elif title.endswith('"') and title.count('"') % 2 == 1:
        # Непарная " в конце — остаток сломанной закрывающей кавычки.
        title = title[:-1].strip()
    return title or None


@functools.lru_cache(maxsize=1)
def _builtin_tasks() -> ConnectorTopics:
    return load_catalog().connector(DEFAULT_CONNECTOR)


def normalize_label(data: dict[str, Any], connector: ConnectorTopics | None = None) -> dict[str, Any]:
    """Проверяет разметку модели и приводит её к формату корпуса.

    Без connector — правила коннектора tasks. Название сохраняется и у createTask без
    кавычек (остаток фразы); у намерений вне title_intents оно сбрасывается в null.
    """
    connector = connector or _builtin_tasks()
    intent = data.get("intent")
    if intent not in connector.intents:
        raise ProviderError(f"недопустимый intent: {intent!r}")
    issue = data.get("issue") or "none"
    if issue not in prompts.ISSUES:
        raise ProviderError(f"недопустимый issue: {issue!r}")
    title_issue = data.get("titleIssue") or "none"
    if title_issue not in prompts.TITLE_ISSUES:
        raise ProviderError(f"недопустимый titleIssue: {title_issue!r}")

    title = _strip_title_quotes(data.get("title"))
    if intent not in connector.title_intents or title_issue != "none":
        title = None

    due = data.get("due")
    due = due.strip() if isinstance(due, str) and due.strip() else None
    precision = data.get("precision")
    if intent not in connector.due_intents:
        due, issue = None, "none"
    if issue != "none":
        due = None
    if due is None:
        precision = None
    else:
        due, precision = _normalize_due(due, precision)

    return {
        "intent": intent,
        "title": title,
        "due": due,
        "precision": precision,
        "issue": issue,
        "titleIssue": title_issue,
        "confident": bool(data.get("confident", True)),
        "comment": str(data.get("comment") or ""),
    }


def _normalize_due(due: str, precision: Any) -> tuple[str, str]:
    """Приводит срок к формату корпуса и сверяет его с precision модели.

    «2026-11-03» → date; «2026-11-03T10:00[:00]» → dateTime. Противоречие
    (precision=date при времени не 00:00, dateTime без времени) — ошибка
    разметки, а не повод угадывать.
    """
    if precision not in (None, "date", "dateTime"):
        raise ProviderError(f"недопустимый precision: {precision!r}")
    has_time = "T" in due or " " in due
    try:
        moment = datetime.fromisoformat(due.replace(" ", "T")) if has_time else datetime.strptime(due, "%Y-%m-%d")
    except ValueError:
        raise ProviderError(f"недопустимый due: {due!r}") from None
    if not 2000 <= moment.year <= 2100:
        raise ProviderError(f"недопустимый год в due: {due!r}")
    if precision is None:
        precision = "dateTime" if has_time else "date"
    if precision == "dateTime" and not has_time:
        raise ProviderError(f"precision=dateTime, но в due нет времени: {due!r}")
    if precision == "date" and has_time and (moment.hour, moment.minute, moment.second) != (0, 0, 0):
        raise ProviderError(f"precision=date, но в due есть время: {due!r}")
    date = f"{moment.year:04d}-{moment.month:02d}-{moment.day:02d}"
    if precision == "date":
        return date, "date"
    return f"{date}T{moment.hour:02d}:{moment.minute:02d}", "dateTime"


def comparable(label_: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(label_.get(field) for field in prompts.LABEL_FIELDS)


def decide(row: dict[str, Any], labelers: list[Source]) -> str:
    names = [s.name for s in labelers]
    labels = [row["labels"][n] for n in names if n in row["labels"]]
    if len(labels) < len(names) or not labels:
        return "error"
    if len(labels) < 2:
        return "disputed"  # один разметчик — нужен человек
    if not all(l["confident"] for l in labels):
        return "disputed"
    if len({comparable(l) for l in labels}) == 1:
        row["final"] = {k: labels[0][k] for k in prompts.LABEL_FIELDS}
        row["final_by"] = sorted(names)
        return "agreed"
    return "disputed"


# ------------------------------------------------------- перенос в корпус


def run_dart_parser(config: Config, items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Прогоняет фразы через текущий ScenarioParser (tool/parse_phrases.dart)."""
    payload = "".join(
        json.dumps({"id": i["cid"], "text": i["text"], "now": i["now"]}, ensure_ascii=False) + "\n"
        for i in items
    )
    completed = subprocess.run(
        [config.dart, "run", "tool/parse_phrases.dart"],
        cwd=config.project_root,
        input=payload,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"dart run завершился с кодом {completed.returncode}:\n{completed.stderr}")
    results: dict[str, dict[str, Any]] = {}
    for line in completed.stdout.split("\n"):
        start = line.find("{")  # dart может печатать служебный текст перед JSON
        if start == -1:
            continue
        row = json.loads(line[start:])
        results[row["id"]] = row
    missing = [i["cid"] for i in items if i["cid"] not in results]
    if missing:
        raise RuntimeError(f"парсер не вернул результат для {missing[:5]}")
    return results


def promote(
    config: Config,
    store: CandidateStore,
    *,
    dry_run: bool = False,
    parser: ParserRunner = run_dart_parser,
    catalog: Catalog | None = None,
) -> Counter[str]:
    """Переносит принятые фразы в generated.jsonl.

    Фразы коннектора tasks сверяются с ScenarioParser (tool/parse_phrases.dart): совпало —
    active, нет — known_gap. Фразы других коннекторов отсюда проверить нечем, поэтому они
    пишутся как active: их маршрутизацию и commandId проверяет test/scenario_corpus_test.dart.
    Писать их как known_gap нельзя — верно размеченная фраза уронила бы этот тест («смените
    status на active»). Коннектор должен быть зарегистрирован в _connectorFactories теста.
    """
    ready = [r for r in store.rows if r["status"] in {"agreed", "accepted"} and r.get("final")]
    counts: Counter[str] = Counter()
    if not ready:
        return counts
    catalog = catalog or catalog_for(config)
    for_parser = [r for r in ready if row_connector(r) == DEFAULT_CONNECTOR]
    parsed = parser(config, for_parser) if for_parser else {}
    existing = corpus_rows(config.corpus_dir)
    existing_ids = {r.get("id") for r in existing}
    existing_texts = {normalize_text(r["text"]) for r in existing if "text" in r}
    lines: list[dict[str, Any]] = []
    for row in ready:
        corpus_id = f"gen-{row['cid']}"
        if corpus_id in existing_ids or normalize_text(row["text"]) in existing_texts:
            row["status"] = "promoted"
            counts["already_in_corpus"] += 1
            continue
        try:
            connector = catalog.connector(row_connector(row))
        except ValueError as error:
            counts["unknown_connector"] += 1
            row.setdefault("errors", []).append(str(error))
            continue
        line = corpus_line(row, connector)
        if connector.id != DEFAULT_CONNECTOR:
            counts["unverified"] += 1
            lines.append(line)
            row["status"] = "promoted"
            continue
        result = parsed[row["cid"]]
        mismatches = [
            f"{field}={value!r}"
            for field in prompts.LABEL_FIELDS
            if field in line or field in {"issue", "titleIssue"}
            for value in [parsed_field(result, field)]
            if value != row["final"].get(field)
        ]
        if mismatches:
            line["status"] = "known_gap"
            line["note"] = "парсер сейчас: " + ", ".join(mismatches)
            counts["known_gap"] += 1
        else:
            counts["active"] += 1
        lines.append(line)
        row["status"] = "promoted"
    if not dry_run:
        append_jsonl(config.corpus_dir / GENERATED_FILE, lines)
        store.save()
    return counts


TARGET_INTENTS = frozenset({"rescheduleTask", "completeTask"})


def parsed_field(parsed: dict[str, Any], field: str) -> Any:
    """Значение поля разбора так, как его сравнивает scenario_corpus_test.dart.

    У переноса и завершения без кавычек слова цели лежат в targetQuery, а title пуст;
    корпус и разметка называют это title — тест сравнивает `title ?? targetQuery`.
    """
    if field == "title" and parsed.get("intent") in TARGET_INTENTS:
        title = parsed.get("title")
        return title if title is not None else parsed.get("targetQuery")
    return parsed.get(field)


def corpus_line(row: dict[str, Any], connector: ConnectorTopics | None = None) -> dict[str, Any]:
    """Строка корпуса; "connector" пишется, только если это не tasks (значение по умолчанию).

    Поля разбора задач (title, due, precision, issue, titleIssue) пишутся только для tasks:
    для других коннекторов scenario_corpus_test.dart их не проверяет и отвергает непустые.
    """
    connector = connector or _builtin_tasks()
    final = row["final"]
    line: dict[str, Any] = {"id": f"gen-{row['cid']}", "text": row["text"]}
    if row["now"] != CORPUS_DEFAULT_NOW:
        line["now"] = row["now"]
    if connector.id != DEFAULT_CONNECTOR:
        line["connector"] = connector.id
    line["intent"] = final["intent"]
    if connector.id != DEFAULT_CONNECTOR:
        line["source"] = row["source"]
        line["tags"] = [f"topic:{row['topic']}", "labels:" + ",".join(row.get("final_by") or ["manual"])]
        return line
    if final["intent"] in connector.title_intents:
        line["title"] = final["title"]
    if final["intent"] in connector.due_intents:
        line["due"] = final["due"]
        if final["precision"] is not None:
            line["precision"] = final["precision"]
    if final["issue"] != "none":
        line["issue"] = final["issue"]
    if final["titleIssue"] != "none":
        line["titleIssue"] = final["titleIssue"]
    line["source"] = row["source"]
    line["tags"] = [f"topic:{row['topic']}", "labels:" + ",".join(row.get("final_by") or ["manual"])]
    return line


# --------------------------------------------------------------- служебное


def _usage_row(source: Source, stage: str, completion: Any) -> dict[str, Any]:
    return {
        "source": source.name,
        "stage": stage,
        "input_tokens": getattr(completion, "input_tokens", 0),
        "output_tokens": getattr(completion, "output_tokens", 0),
        "cost_usd": round(
            source.cost(getattr(completion, "input_tokens", 0), getattr(completion, "output_tokens", 0)), 6
        ),
    }


def _run_parallel(sources: list[Source], run: Callable[[Source], None]) -> None:
    if not sources:
        return
    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        list(pool.map(run, sources))
