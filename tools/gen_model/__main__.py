"""python -m tools.gen_model <шаг> --model qwen3-1.7b|qwen2.5-1.5b|qwen3-4b

  fetch   скачать GGUF (закреплённая ревизия) и сверить sha256
  intent  честная проверка подсказки при «не понял» → out/<модель>/intent.json
          (--shots N: N фраз на команду из снимка корпуса → intent-shotsN.json)
  bench   скорость, память, пример ответа → out/<модель>/bench.json
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


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("step", choices=["fetch", "intent", "bench"])
    ap.add_argument("--model", required=True, choices=sorted(config.MODELS))
    ap.add_argument("--threads", type=int, default=config.THREADS)
    ap.add_argument("--shots", type=int, default=0)
    args = ap.parse_args(argv)
    m = config.model(args.model)
    out = config.OUT / m.name
    if args.step == "fetch":
        fetch(m)
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
