"""Конвейер: генерация → перекрёстная разметка → проверка человеком → перенос в корпус."""

from __future__ import annotations

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
from .providers import Provider, ProviderError, make_provider
from .store import CandidateStore, append_jsonl, candidate_id, corpus_rows, normalize_text

ProviderFactory = Callable[[Source], Provider]
ParserRunner = Callable[[Config, list[dict[str, Any]]], dict[str, dict[str, Any]]]

GENERATED_FILE = "generated.jsonl"

# Значение «сейчас» по умолчанию в test/scenario_corpus_test.dart.
CORPUS_DEFAULT_NOW = "2026-11-02T16:30"

_TOPIC_INTENTS = {
    "create": {"createTask"},
    "reschedule": {"rescheduleTask"},
    "complete": {"completeTask"},
    "list": {"listTasks"},
    "unknown": {"unknown"},
}


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
) -> Report:
    if topic not in prompts.TOPICS:
        raise ValueError(f"неизвестная тема «{topic}»; доступны: {', '.join(prompts.TOPICS)}")
    report = Report()
    known = _known_texts(config, store)
    examples = _examples(config, topic)
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
                    prompts.generation_prompt(topic, size, examples),
                    prompts.GENERATION_SCHEMA,
                )
            except Exception as error:  # noqa: BLE001 — сеть, лимиты, отказ, не-JSON
                with lock:
                    report.error(f"{source.name}: {error}")
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
                    if not _add_candidate(store, known, phrase, source.name, source.family, topic, config):
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
) -> Report:
    """Фразы, вставленные из веб-чатов. Номера списков и маркеры срезаются, кавычки — нет."""
    report = Report()
    known = _known_texts(config, store)
    for raw in lines:
        phrase = re.sub(r"^\s*(?:\d+[.)]\s+|[-*•–—]\s+)", "", raw).strip()
        if not phrase:
            continue
        if _add_candidate(store, known, phrase, source_name, f"manual:{source_name}", topic, config):
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
    topic: str,
    config: Config,
) -> bool:
    key = normalize_text(phrase)
    if key in known:
        return False
    known.add(key)
    store.rows.append(
        {
            "cid": candidate_id(phrase),
            "text": phrase,
            "now": config.default_now,
            "source": source,
            "family": family,
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


def _examples(config: Config, topic: str) -> list[str]:
    intents = _TOPIC_INTENTS.get(topic)
    rows = corpus_rows(config.corpus_dir)
    return [r["text"] for r in rows if r.get("text") and (intents is None or r.get("intent") in intents)]


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
) -> Counter[str]:
    pending = [row for row in store.rows if row["status"] in {"new", "error"}]
    if limit is not None:
        pending = pending[:limit]
    providers: dict[str, Provider] = {}
    semaphores = {s.name: threading.Semaphore(s.max_concurrency) for s in labelers}
    lock = threading.Lock()
    usage: list[dict[str, Any]] = []
    jobs: list[tuple[dict[str, Any], Source]] = []

    for row in pending:
        for source in choose_labelers(row, labelers):
            if source.name not in row["labels"]:
                jobs.append((row, source))
            if source.name not in providers:
                providers[source.name] = factory(source)

    def run(job: tuple[dict[str, Any], Source]) -> None:
        row, source = job
        with semaphores[source.name]:
            try:
                completion = providers[source.name].complete(
                    prompts.LABEL_SYSTEM,
                    prompts.label_prompt(row["text"], row["now"]),
                    prompts.LABEL_SCHEMA,
                )
                result = normalize_label(completion.data)
            except Exception as error:  # noqa: BLE001
                with lock:
                    row.setdefault("errors", []).append(f"{source.name}: {error}")
                return
        with lock:
            row["labels"][source.name] = result
            usage.append(_usage_row(source, "label", completion))

    workers = max(1, sum(s.max_concurrency for s in labelers))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(run, jobs))

    counts: Counter[str] = Counter()
    for row in pending:
        row["status"] = decide(row, choose_labelers(row, labelers))
        counts[row["status"]] += 1
    store.record_usage(usage)
    store.save()
    return counts


def normalize_label(data: dict[str, Any]) -> dict[str, Any]:
    """Проверяет разметку модели и приводит её к формату корпуса."""
    intent = data.get("intent")
    if intent not in prompts.INTENTS:
        raise ProviderError(f"недопустимый intent: {intent!r}")
    issue = data.get("issue") or "none"
    if issue not in prompts.ISSUES:
        raise ProviderError(f"недопустимый issue: {issue!r}")
    title_issue = data.get("titleIssue") or "none"
    if title_issue not in prompts.TITLE_ISSUES:
        raise ProviderError(f"недопустимый titleIssue: {title_issue!r}")

    title = data.get("title")
    title = title.strip() if isinstance(title, str) and title.strip() else None
    if intent in {"listTasks", "unknown"} or title_issue != "none":
        title = None

    due = data.get("due")
    due = due.strip() if isinstance(due, str) and due.strip() else None
    precision = data.get("precision")
    if intent not in {"createTask", "rescheduleTask"}:
        due, issue = None, "none"
    if issue != "none":
        due = None
    if due is None:
        precision = None
    else:
        due, precision = _normalize_due(due)

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


def _normalize_due(due: str) -> tuple[str, str]:
    """«2026-11-03» → date; «2026-11-03T10:00[:00]» → dateTime, без секунд."""
    try:
        if "T" not in due and " " not in due:
            return datetime.strptime(due, "%Y-%m-%d").strftime("%Y-%m-%d"), "date"
        moment = datetime.fromisoformat(due.replace(" ", "T"))
    except ValueError:
        raise ProviderError(f"недопустимый due: {due!r}") from None
    return moment.strftime("%Y-%m-%dT%H:%M"), "dateTime"


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
    for line in completed.stdout.splitlines():
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
) -> Counter[str]:
    ready = [r for r in store.rows if r["status"] in {"agreed", "accepted"} and r.get("final")]
    counts: Counter[str] = Counter()
    if not ready:
        return counts
    parsed = parser(config, ready)
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
        line = corpus_line(row)
        mismatches = [
            f"{field}={parsed[row['cid']].get(field)!r}"
            for field in prompts.LABEL_FIELDS
            if field in line or field in {"issue", "titleIssue"}
            if parsed[row["cid"]].get(field) != row["final"].get(field)
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


def corpus_line(row: dict[str, Any]) -> dict[str, Any]:
    final = row["final"]
    line: dict[str, Any] = {"id": f"gen-{row['cid']}", "text": row["text"]}
    if row["now"] != CORPUS_DEFAULT_NOW:
        line["now"] = row["now"]
    line["intent"] = final["intent"]
    if final["intent"] in {"createTask", "rescheduleTask", "completeTask"}:
        line["title"] = final["title"]
    if final["intent"] in {"createTask", "rescheduleTask"}:
        line["due"] = final["due"]
        if final["precision"] is not None:
            line["precision"] = final["precision"]
    if final["issue"] != "none":
        line["issue"] = final["issue"]
    if final["titleIssue"] != "none":
        line["titleIssue"] = final["titleIssue"]
    line["source"] = row["source"]
    line["tags"] = [f"topic:{row['topic']}", "labels:" + ",".join(sorted(row["labels"]))]
    return line


# --------------------------------------------------------------- служебное


def _usage_row(source: Source, stage: str, completion: Any) -> dict[str, Any]:
    return {
        "source": source.name,
        "stage": stage,
        "input_tokens": completion.input_tokens,
        "output_tokens": completion.output_tokens,
        "cost_usd": round(source.cost(completion.input_tokens, completion.output_tokens), 6),
    }


def _run_parallel(sources: list[Source], run: Callable[[Source], None]) -> None:
    if not sources:
        return
    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        list(pool.map(run, sources))
