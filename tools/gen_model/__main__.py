"""python -m tools.gen_model <шаг> --model qwen3-1.7b|qwen2.5-1.5b|qwen3-4b

  fetch   скачать GGUF (закреплённая ревизия) и сверить sha256
  intent  честная проверка подсказки при «не понял» → out/<модель>/intent.json
          (--shots N: N фраз на команду из снимка корпуса → intent-shotsN.json)
  bench   скорость, память, пример ответа → out/<модель>/bench.json
  tasks   поля в карточку, таблицы, пересказ → out/<модель>/tasks.json
  agree   согласие с «Лёгкой» (нужны пробы holdout tools/intent_model)
          → out/<модель>/agree-<tag>.json; --tag intent|intent-shots3
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

from . import config

BENCH_TEXT = (
    "Перескажи в двух предложениях: склад получил 40 коробок молока, 12 из них "
    "с повреждённой упаковкой; поставщик обещал заменить их в пятницу."
)


def fetch(m: config.Model) -> None:
    from .runner import sha256

    config.CACHE.mkdir(parents=True, exist_ok=True)
    if not m.path.exists() or sha256(m.path) != m.sha256:
        subprocess.run(["curl", "-fsSL", "--retry", "4", "-C", "-", "-o", str(m.path), m.url], check=True)
    got = sha256(m.path)
    if got != m.sha256:
        m.path.unlink()
        raise SystemExit(f"{m.file}: sha256 {got} ≠ {m.sha256}, файл удалён")
    print(m.path)


def run_tasks(runner) -> dict:
    import time

    from . import tasks

    def timed(fn):
        started = time.perf_counter()
        value = fn()
        return value, time.perf_counter() - started

    log: list[dict] = []
    fields = tasks.read_jsonl("fields.jsonl")
    outs, secs = [], []
    for r in fields:
        raw, s = timed(lambda: runner.complete(tasks.FIELDS_SYSTEM, r["text"], tasks.FIELDS_SCHEMA))
        secs.append(s)
        try:
            outs.append(json.loads(raw))
        except json.JSONDecodeError:
            outs.append(None)
        log.append({"task": "fields", "id": r["id"], "out": raw})
    result = {"fields": tasks.fields_score(fields, outs) | {"seconds_median": round(sorted(secs)[len(secs) // 2], 2)}}

    questions = tasks.read_jsonl("tables.jsonl")
    ok, secs = 0, []
    for r in questions:
        rows = tasks.load_table(r["table"])
        schema = tasks.table_schema(list(rows[0]))
        raw, s = timed(lambda: runner.complete(tasks.table_system(rows), r["question"], schema))
        secs.append(s)
        try:
            got = tasks.run_query(rows, json.loads(raw))
        except (json.JSONDecodeError, KeyError, TypeError):
            got = None
        good = tasks.answer_ok(got, r["answer"])
        ok += good
        log.append({"task": "tables", "id": r["id"], "out": raw, "got": got, "ok": good})
    result["tables"] = {
        "correct": round(100 * ok / len(questions), 1),
        "questions": len(questions),
        "seconds_median": round(sorted(secs)[len(secs) // 2], 2),
    }

    texts = tasks.read_jsonl("summary.jsonl")
    outs, secs = [], []
    for r in texts:
        raw, s = timed(lambda: runner.complete(tasks.SUMMARY_SYSTEM, r["text"], max_tokens=160))
        secs.append(s)
        outs.append(raw)
        log.append({"task": "summary", "id": r["id"], "out": raw})
    result["summary"] = tasks.summary_score(texts, outs) | {"seconds_median": round(sorted(secs)[len(secs) // 2], 2)}
    result["log"] = log
    return result


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("step", choices=["fetch", "intent", "bench", "tasks", "agree"])
    ap.add_argument("--model", required=True, choices=sorted(config.MODELS))
    ap.add_argument("--threads", type=int, default=config.THREADS)
    ap.add_argument("--shots", type=int, default=0)
    ap.add_argument("--tag", default="intent-shots3")
    args = ap.parse_args(argv)
    m = config.model(args.model)
    out = config.OUT / m.name
    if args.step == "fetch":
        fetch(m)
        return
    if args.step == "agree":
        from tools.intent_model import config as intent_config

        from . import agree

        result = agree.run(
            out / f"{args.tag}_preds.jsonl",
            intent_config.OUT / "accurate" / "calib",
            out / f"agree-{args.tag}.json",
        )
        json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return
    from . import intent_eval
    from .runner import Runner, rss_mb

    runner = Runner(m, threads=args.threads)
    if args.step == "intent":
        descriptions = intent_eval.labels()
        tag = f"intent-shots{args.shots}" if args.shots else "intent"
        if args.shots:

            def prepare(set_name):
                runner.prepare_labels(descriptions, intent_eval.examples(set_name, args.shots))

            result = intent_eval.run(runner.choose, m.name, out, prepare=prepare, tag=tag)
        else:
            runner.prepare_labels(descriptions)
            result = intent_eval.run(runner.choose, m.name, out, tag=tag)
        result["shots"] = args.shots
        result["prefix_tokens"] = len(runner.prefix)
        result["prefix_seconds"] = round(runner.prefix_seconds, 1)
        result["threads"] = args.threads
        (out / f"{tag}.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    elif args.step == "tasks":
        result = run_tasks(runner)
        result["model"] = m.name
        out.mkdir(parents=True, exist_ok=True)
        (out / "tasks.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    else:
        result = {
            "model": m.name,
            "file_mb": round(m.path.stat().st_size / 1e6),
            "load_seconds": round(runner.load_seconds, 2),
            "load_rss_mb": round(runner.load_rss_mb),
            "threads": args.threads,
            "generate": runner.bench_generate(BENCH_TEXT),
            "rss_mb": round(rss_mb()),
        }
        out.mkdir(parents=True, exist_ok=True)
        (out / "bench.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
