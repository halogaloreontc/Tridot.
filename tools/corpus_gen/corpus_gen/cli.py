"""Командная строка: corpus-gen <команда>. Подробности — tools/corpus_gen/README.md."""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable

from . import pipeline, prompts
from .config import Config, Source, load_config
from .store import CandidateStore, LockedError, WorkLock
from .topics import DEFAULT_CONNECTOR, ConnectorTopics, row_connector

DEFAULT_CONFIG = Path(__file__).resolve().parent.parent / "config.toml"

# Команды, которые пишут в work/: им нужна блокировка work/.lock.
WRITING_COMMANDS = frozenset({"generate", "label", "review", "promote", "import-manual", "relabel"})

# Код выхода при прерывании, как у оболочки после Ctrl+C.
INTERRUPTED_EXIT = 130


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="corpus-gen", description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="путь к config.toml")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("sources", help="какие источники доступны и почему нет")
    commands.add_parser("topics", help="коннекторы и темы из topics/*.toml")

    gen = commands.add_parser("generate", help="сгенерировать фразы-кандидаты")
    gen.add_argument(
        "--topic",
        required=True,
        help="тема: «create» (коннектор tasks) или «коннектор:тема»; список — corpus-gen topics",
    )
    gen.add_argument("--count", type=int, default=20, help="фраз от каждого источника")
    gen.add_argument("--source", action="append", help="только эти источники (можно несколько)")

    lab = commands.add_parser("label", help="перекрёстно разметить новые фразы")
    lab.add_argument("--limit", type=int, help="не больше N фраз за запуск")
    lab.add_argument("--source", action="append", help="только эти разметчики")

    rev = commands.add_parser("review", help="решить спорные фразы вручную")
    rev.add_argument("--include-agreed", action="store_true", help="показать и согласованные")

    pro = commands.add_parser("promote", help="перенести принятые фразы в test/corpus")
    pro.add_argument("--dry-run", action="store_true", help="только показать, что будет")

    imp = commands.add_parser("import-manual", help="добавить фразы из текстового файла")
    imp.add_argument("file", type=Path, help="по одной фразе на строку")
    imp.add_argument("--source", required=True, help="откуда фразы, например kimi-web")
    imp.add_argument("--topic", default="manual", help="метка темы, можно «коннектор:тема»")

    rel = commands.add_parser("relabel", help="сбросить разметку, чтобы разметить фразы заново")
    rel.add_argument(
        "--include-reviewed",
        action="store_true",
        help="сбросить и ваши решения из review (принятые и отклонённые)",
    )

    commands.add_parser("stats", help="статистика по источникам и расходам")

    args = parser.parse_args(argv)
    if not args.config.exists():
        print(
            f"Нет файла {args.config}. Скопируйте config.example.toml в config.toml.",
            file=sys.stderr,
        )
        return 2
    try:
        config = load_config(args.config)
    except ValueError as error:
        print(f"Ошибка в {args.config}: {error}", file=sys.stderr)
        return 2
    handlers: dict[str, Callable[[Config, CandidateStore, argparse.Namespace], int]] = {
        "sources": _sources,
        "topics": _topics,
        "generate": _generate,
        "label": _label,
        "review": _review,
        "promote": _promote,
        "import-manual": _import_manual,
        "relabel": _relabel,
        "stats": _stats,
    }
    handler = handlers[args.command]
    if args.command not in WRITING_COMMANDS:
        return handler(config, CandidateStore(config.work_dir), args)
    try:
        lock = WorkLock(config.work_dir)
        lock.acquire()
    except LockedError as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 2
    try:
        # Фразы читаются уже под блокировкой: другой процесс их не перепишет.
        return handler(config, CandidateStore(config.work_dir), args)
    finally:
        lock.release()


def _pick(config: Config, role: str, names: list[str] | None) -> list[Source]:
    if not names:
        return config.available(role)
    picked = []
    for name in names:
        source = config.source(name)
        reason = source.unavailable_reason()
        if reason:
            print(f"Пропускаю {name}: {reason}", file=sys.stderr)
        elif role not in source.roles:
            print(f"Пропускаю {name}: нет роли {role}", file=sys.stderr)
        else:
            picked.append(source)
    return picked


def _sources(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    for source in config.sources:
        reason = source.unavailable_reason()
        state = "готов" if reason is None else f"недоступен: {reason}"
        roles = ",".join(sorted(source.roles))
        print(f"{source.name:<16} {source.family:<10} {roles:<15} {source.model:<28} {state}")
    return 0


def _topics(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    try:
        catalog = pipeline.catalog_for(config)
    except ValueError as error:
        print(f"Ошибка тем: {error}", file=sys.stderr)
        return 2
    for connector in catalog.connectors.values():
        print(f"{connector.id} — {connector.title} ({connector.path})")
        print(f"  намерения: {', '.join(connector.intents)}")
        prefix = "" if connector.id == DEFAULT_CONNECTOR else f"{connector.id}:"
        for topic in connector.topics.values():
            print(f"  {prefix + topic.name:<24} {topic.description[:90]}")
    return 0


def _generate(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    try:
        pipeline.catalog_for(config).resolve(args.topic)
    except ValueError as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 2
    sources = _pick(config, "generate", args.source)
    if not sources:
        print("Нет доступных генераторов. Проверьте `corpus-gen sources`.", file=sys.stderr)
        return 1
    try:
        report = pipeline.generate(config, store, args.topic, args.count, sources)
    except pipeline.Interrupted as stopped:
        print(
            f"\nПрервано. Новых фраз сохранено: {stopped.saved}, не выполнено запросов: "
            f"{stopped.remaining}. Сохранённое уже в {store.path}; запустите `corpus-gen generate` "
            "ещё раз, если фраз мало.",
            file=sys.stderr,
        )
        return INTERRUPTED_EXIT
    print(f"Добавлено фраз: {report.added}, дублей пропущено: {report.duplicates}")
    _print_secret_dropped(report.secret_dropped)
    for error in report.errors or []:
        print(f"Ошибка: {error}", file=sys.stderr)
    return 0 if not report.errors else 1


def _label(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    labelers = _pick(config, "label", args.source)
    if not labelers:
        print("Нет доступных разметчиков. Проверьте `corpus-gen sources`.", file=sys.stderr)
        return 1
    if len({s.family for s in labelers}) < 3:
        if config.single_labeler_check:
            print(
                "Разметчиков из разных семейств меньше трёх: у фраз с одним разметчиком разметка "
                "сверяется с приложением, на ручную проверку уходят только расхождения.",
                file=sys.stderr,
            )
        elif len({s.family for s in labelers}) < 2:
            print(
                "Внимание: разметчиков из разных семейств меньше двух — все фразы уйдут на ручную проверку.",
                file=sys.stderr,
            )
    try:
        counts = pipeline.label(config, store, labelers, limit=args.limit, on_progress=ProgressLine("Разметка"))
    except pipeline.Interrupted as stopped:
        print(
            f"\nПрервано. Разметок сохранено за этот запуск: {stopped.saved}, осталось запросов: "
            f"{stopped.remaining}. Запустите `corpus-gen label` ещё раз — разметка продолжится, "
            "уже полученные разметки повторно не запрашиваются.",
            file=sys.stderr,
        )
        return INTERRUPTED_EXIT
    print(_label_summary(counts))
    if counts.get(pipeline.CHECK_FAILED):
        print(
            f"Проверка приложением не удалась у фраз: {counts[pipeline.CHECK_FAILED]} — они остались "
            "disputed, причина видна в `corpus-gen review`. Проверьте `dart run tool/route_phrases.dart`.",
            file=sys.stderr,
        )
    return 0


class ProgressLine:
    """Строка «Разметка: 120 из 400 (30%), осталось ≈ 1 ч 10 мин» в stderr не чаще раза в 30 с.

    Локальные модели размечают часами, а без индикатора не видно, идёт ли работа.
    """

    INTERVAL = 30.0

    def __init__(self, title: str, clock: Callable[[], float] = time.monotonic, stream: Any = None) -> None:
        self.title = title
        self.clock = clock
        self.stream = stream
        self.started: float | None = None
        self.shown_at: float | None = None
        self.shown: tuple[int, int] | None = None

    def __call__(self, done: int, total: int) -> None:
        now = self.clock()
        if self.started is None:
            self.started = now
        if total <= 0 or (done, total) == self.shown:
            return
        if self.shown_at is not None and now - self.shown_at < self.INTERVAL and done < total:
            return
        self.shown_at, self.shown = now, (done, total)
        line = f"{self.title}: {done} из {total} ({100 * done // total}%)"
        elapsed = now - self.started
        if 0 < done < total and elapsed > 0:
            line += f", осталось ≈ {_duration(elapsed / done * (total - done))}"
        print(line, file=self.stream or sys.stderr, flush=True)


def _duration(seconds: float) -> str:
    minutes = max(1, round(seconds / 60))
    hours, minutes = divmod(minutes, 60)
    return f"{hours} ч {minutes} мин" if hours else f"{minutes} мин"


def _print_secret_dropped(count: int) -> None:
    """Сколько фраз отброшено фильтром секретов; сами фразы не печатаются никогда."""
    if count:
        print(f"Отброшено фраз, похожих на секрет (пароль, код, логин, почта, телефон): {count}")


def _label_summary(counts: Counter[str]) -> str:
    extra = {pipeline.AGREED_BY_PARSER, pipeline.RECHECKED, pipeline.CHECK_FAILED, pipeline.SECRET_DROPPED}
    statuses = [f"{k}={v}" for k, v in sorted(counts.items()) if k not in extra]
    if not statuses:
        if counts.get(pipeline.SECRET_DROPPED):
            return f"Итог разметки: нечего размечать; отклонено как похожие на секрет={counts[pipeline.SECRET_DROPPED]}"
        return "Итог разметки: нечего размечать"
    details = []
    if counts.get(pipeline.AGREED_BY_PARSER):
        details.append(f"agreed (по парсеру)={counts[pipeline.AGREED_BY_PARSER]}")
    if counts.get(pipeline.RECHECKED):
        details.append(f"перепроверено спорных с одной разметкой={counts[pipeline.RECHECKED]}")
    if counts.get(pipeline.CHECK_FAILED):
        details.append(f"проверка не удалась={counts[pipeline.CHECK_FAILED]}")
    if counts.get(pipeline.SECRET_DROPPED):
        details.append(f"отклонено как похожие на секрет={counts[pipeline.SECRET_DROPPED]}")
    summary = "Итог разметки: " + ", ".join(statuses)
    return summary + (f"; из них {', '.join(details)}" if details else "")


def _review(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    statuses = {"disputed", "agreed"} if args.include_agreed else {"disputed"}
    queue = [row for row in store.rows if row["status"] in statuses]
    if not queue:
        print("Спорных фраз нет.")
        return 0
    catalog = pipeline.catalog_for(config)
    print(f"Фраз на проверку: {len(queue)}. Команды: номер разметки, e — ввести JSON, "
          "r — отклонить, s — пропустить, q — выйти.")
    for index, row in enumerate(queue, start=1):
        print(f"\n[{index}/{len(queue)}] {row['text']}")
        print(
            f"    сейчас: {row['now']}  источник: {row['source']}  "
            f"коннектор: {row_connector(row)}  тема: {row['topic']}"
        )
        names = sorted(row["labels"])
        for number, name in enumerate(names, start=1):
            label = row["labels"][name]
            fields = {k: label.get(k) for k in prompts.LABEL_FIELDS}
            comment = f"  // {label['comment']}" if label.get("comment") else ""
            confident = "" if label.get("confident", True) else "  [не уверен]"
            print(f"  {number}. {name}: {json.dumps(fields, ensure_ascii=False)}{confident}{comment}")
        if row.get("check"):
            print(f"    проверка: {row['check']}")
        elif row["status"] == "agreed" and pipeline.APP_CHECK_MARK in (row.get("final_by") or []):
            print("    проверка: совпало с приложением (единственный разметчик)")
        while True:
            try:
                answer = input("> ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                answer = "q"
                print()
            if answer == "q":
                store.save()
                return 0
            if answer == "s":
                break
            if answer == "r":
                row["status"] = "rejected"
                break
            if answer == "e":
                try:
                    connector = catalog.connector(row_connector(row))
                except ValueError as error:
                    print(f"Ошибка: {error}")
                    continue
                try:
                    final = _ask_json(connector)
                except (EOFError, KeyboardInterrupt):
                    print()
                    store.save()
                    return 0
                if final is not None:
                    row["final"], row["status"] = final, "accepted"
                    row["final_by"] = ["manual"]
                    break
                continue
            if answer.isdigit() and 1 <= int(answer) <= len(names):
                chosen = names[int(answer) - 1]
                label = row["labels"][chosen]
                row["final"] = {k: label.get(k) for k in prompts.LABEL_FIELDS}
                row["status"] = "accepted"
                row["final_by"] = [chosen, "manual"]
                break
            print("Не понял. Номер разметки, e, r, s или q.")
        store.save()
    return 0


def _ask_json(connector: ConnectorTopics) -> dict[str, Any] | None:
    print('Введите JSON одной строкой, например {"intent":"createTask","title":"Отчёт","due":null}')
    text = input("json> ")  # EOFError/KeyboardInterrupt обрабатывает вызывающий
    try:
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError("нужен JSON-объект")
        label = pipeline.normalize_label({"confident": True, **data}, connector)
    except (ValueError, pipeline.ProviderError) as error:
        print(f"Ошибка: {error}")
        return None
    return {k: label[k] for k in prompts.LABEL_FIELDS}


def _promote(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    counts = pipeline.promote(config, store, dry_run=args.dry_run)
    if not counts:
        print("Нечего переносить: нет согласованных или принятых фраз.")
        return 0
    target = config.corpus_dir / pipeline.GENERATED_FILE
    prefix = "Будет добавлено" if args.dry_run else f"Добавлено в {target}"
    print(f"{prefix}: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if counts.get("known_gap") and not args.dry_run:
        print("Фразы со status=known_gap парсер пока понимает неверно — это список работ.")
    if counts.get("unverified") and not args.dry_run:
        print(
            "Фразы других коннекторов (unverified) записаны как active: проверьте их командой "
            "flutter test test/scenario_corpus_test.dart."
        )
    return 0


def _import_manual(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    try:
        # utf-8-sig убирает BOM, который добавляют некоторые редакторы.
        lines = args.file.read_text(encoding="utf-8-sig").split("\n")
    except FileNotFoundError:
        print(f"Нет файла {args.file}", file=sys.stderr)
        return 2
    except UnicodeDecodeError:
        print(f"{args.file}: файл должен быть в UTF-8", file=sys.stderr)
        return 2
    try:
        report = pipeline.import_manual(config, store, lines, args.source, args.topic)
    except ValueError as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 2
    print(f"Добавлено фраз: {report.added}, дублей пропущено: {report.duplicates}")
    _print_secret_dropped(report.secret_dropped)
    return 0


def _relabel(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    count = pipeline.relabel(store, include_reviewed=args.include_reviewed)
    print(f"Разметка сброшена у фраз: {count}. Запустите `corpus-gen label`.")
    return 0


def _stats(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    by_source: dict[str, Counter[str]] = defaultdict(Counter)
    for row in store.rows:
        by_source[row["source"]][row["status"]] += 1
    print("Фразы по источникам:")
    for source, counts in sorted(by_source.items()):
        total = sum(counts.values())
        detail = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
        print(f"  {source:<16} всего {total:<5} {detail}")
    spend: dict[str, list[float]] = defaultdict(lambda: [0, 0, 0.0])
    for row in store.usage():
        bucket = spend[row["source"]]
        bucket[0] += row["input_tokens"]
        bucket[1] += row["output_tokens"]
        bucket[2] += row["cost_usd"]
    if spend:
        print("Расход (по ценам из config.toml):")
        for source, (tokens_in, tokens_out, cost) in sorted(spend.items()):
            print(f"  {source:<16} вход {int(tokens_in):>9}  выход {int(tokens_out):>9}  ${cost:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
