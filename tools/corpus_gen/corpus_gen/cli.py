"""Командная строка: corpus-gen <команда>. Подробности — tools/corpus_gen/README.md."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable

from . import pipeline, prompts
from .config import Config, Source, load_config
from .store import CandidateStore

DEFAULT_CONFIG = Path(__file__).resolve().parent.parent / "config.toml"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="corpus-gen", description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="путь к config.toml")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("sources", help="какие источники доступны и почему нет")

    gen = commands.add_parser("generate", help="сгенерировать фразы-кандидаты")
    gen.add_argument("--topic", required=True, choices=sorted(prompts.TOPICS))
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
    imp.add_argument("--topic", default="manual")

    commands.add_parser("stats", help="статистика по источникам и расходам")

    args = parser.parse_args(argv)
    if not args.config.exists():
        print(
            f"Нет файла {args.config}. Скопируйте config.example.toml в config.toml.",
            file=sys.stderr,
        )
        return 2
    config = load_config(args.config)
    store = CandidateStore(config.work_dir)
    handlers: dict[str, Callable[[Config, CandidateStore, argparse.Namespace], int]] = {
        "sources": _sources,
        "generate": _generate,
        "label": _label,
        "review": _review,
        "promote": _promote,
        "import-manual": _import_manual,
        "stats": _stats,
    }
    return handlers[args.command](config, store, args)


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


def _generate(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    sources = _pick(config, "generate", args.source)
    if not sources:
        print("Нет доступных генераторов. Проверьте `corpus-gen sources`.", file=sys.stderr)
        return 1
    report = pipeline.generate(config, store, args.topic, args.count, sources)
    print(f"Добавлено фраз: {report.added}, дублей пропущено: {report.duplicates}")
    for error in report.errors or []:
        print(f"Ошибка: {error}", file=sys.stderr)
    return 0 if not report.errors else 1


def _label(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    labelers = _pick(config, "label", args.source)
    if not labelers:
        print("Нет доступных разметчиков. Проверьте `corpus-gen sources`.", file=sys.stderr)
        return 1
    if len({s.family for s in labelers}) < 2:
        print(
            "Внимание: разметчиков из разных семейств меньше двух — все фразы уйдут на ручную проверку.",
            file=sys.stderr,
        )
    counts = pipeline.label(config, store, labelers, limit=args.limit)
    print("Итог разметки: " + (", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "нечего размечать"))
    return 0


def _review(config: Config, store: CandidateStore, args: argparse.Namespace) -> int:
    statuses = {"disputed", "agreed"} if args.include_agreed else {"disputed"}
    queue = [row for row in store.rows if row["status"] in statuses]
    if not queue:
        print("Спорных фраз нет.")
        return 0
    print(f"Фраз на проверку: {len(queue)}. Команды: номер разметки, e — ввести JSON, "
          "r — отклонить, s — пропустить, q — выйти.")
    for index, row in enumerate(queue, start=1):
        print(f"\n[{index}/{len(queue)}] {row['text']}")
        print(f"    сейчас: {row['now']}  источник: {row['source']}  тема: {row['topic']}")
        names = sorted(row["labels"])
        for number, name in enumerate(names, start=1):
            label = row["labels"][name]
            fields = {k: label[k] for k in prompts.LABEL_FIELDS}
            comment = f"  // {label['comment']}" if label.get("comment") else ""
            confident = "" if label.get("confident", True) else "  [не уверен]"
            print(f"  {number}. {name}: {json.dumps(fields, ensure_ascii=False)}{confident}{comment}")
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
                    final = _ask_json()
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
                row["final"] = {k: label[k] for k in prompts.LABEL_FIELDS}
                row["status"] = "accepted"
                row["final_by"] = [chosen, "manual"]
                break
            print("Не понял. Номер разметки, e, r, s или q.")
        store.save()
    return 0


def _ask_json() -> dict[str, Any] | None:
    print('Введите JSON одной строкой, например {"intent":"createTask","title":"Отчёт","due":null}')
    text = input("json> ")  # EOFError/KeyboardInterrupt обрабатывает вызывающий
    try:
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError("нужен JSON-объект")
        label = pipeline.normalize_label({"confident": True, **data})
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
    report = pipeline.import_manual(config, store, lines, args.source, args.topic)
    print(f"Добавлено фраз: {report.added}, дублей пропущено: {report.duplicates}")
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
