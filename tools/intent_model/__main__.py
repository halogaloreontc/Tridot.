"""python -m tools.intent_model <шаг> --tier light|accurate|web …

Подробно — tools/intent_model/README.md.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from . import config, data, pack, pipeline


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m tools.intent_model", description="Сборка модели понимания (ADR-045)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def tier_arg(p, required=True):
        p.add_argument("--tier", choices=list(config.TIERS), required=required)

    p = sub.add_parser("build", help="всё подряд: пробы, модель, порог, индекс, проверка, архив")
    tier_arg(p)
    p.add_argument("--version", default="0.0.0-local")
    p.add_argument("--reuse", action="store_true", help="не пересобирать готовые пробы и модель")
    p.add_argument("--no-strict", action="store_true", help="собрать архив и вне бюджета ошибок")

    p = sub.add_parser("prepare", help="корпус → out/<уровень>/data/train.jsonl")
    tier_arg(p)

    p = sub.add_parser("holdout", help="модель снимка корпуса до разбора пробы → calib/<проба>.npz")
    tier_arg(p)
    p.add_argument("--set", choices=sorted({s for t in config.TIERS for s in config.holdout_sets(t)}), required=True)

    p = sub.add_parser("model", help="дообучение на текущем корпусе, ONNX int8, векторы примеров")
    tier_arg(p)

    for name, hlp in (("calibrate", "порог на int8 по честным пробам"), ("index", "index.bin и labels.json"),
                      ("verify", "метрики → metrics.json")):
        tier_arg(sub.add_parser(name, help=hlp))

    p = sub.add_parser("pack", help="manifest.json и архив")
    tier_arg(p)
    p.add_argument("--version", required=True)

    p = sub.add_parser("finish", help="calibrate + index + verify + pack")
    tier_arg(p)
    p.add_argument("--version", required=True)
    p.add_argument("--no-strict", action="store_true")

    p = sub.add_parser("latest", help="latest.json выпуска из архивов")
    p.add_argument("--version", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("zips", nargs="+")

    tier_arg(sub.add_parser("webcheck", help="модель пакета в onnxruntime-web (node, WASM)"))

    sub.add_parser("check-labels", help="у каждой метки корпуса есть описание")

    a = ap.parse_args(argv)
    if getattr(a, "version", None) and not re.fullmatch(r"\d{1,4}\.\d{1,4}\.\d{1,4}(-[a-z0-9.]+)?", a.version):
        ap.error("версия — три числа через точку: 1.0.0")
    t = config.tier(a.tier) if getattr(a, "tier", None) else None
    if a.cmd == "build":
        pipeline.build(t, a.version, reuse=a.reuse, strict=not a.no_strict)
    elif a.cmd == "prepare":
        pipeline.prepare(t)
    elif a.cmd == "holdout":
        pipeline.holdout(t, a.set)
    elif a.cmd == "model":
        pipeline.build_model(t)
    elif a.cmd == "calibrate":
        pipeline.calibrate(t)
    elif a.cmd == "index":
        pipeline.index(t)
    elif a.cmd == "verify":
        if not pipeline.verify(t)["ok"]:
            return 1
    elif a.cmd == "pack":
        pipeline.do_pack(t, a.version)
    elif a.cmd == "finish":
        pipeline.finish(t, a.version, strict=not a.no_strict)
    elif a.cmd == "latest":
        body = pack.latest(a.version, a.base_url, [Path(z) for z in a.zips])
        Path(a.out).write_text(json.dumps(body, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(json.dumps(body, ensure_ascii=False, indent=1))
    elif a.cmd == "webcheck":
        pipeline.webcheck(t)
    elif a.cmd == "check-labels":
        rows, _ = data.prepare(data.corpus_files())
        data.check_descriptions([r["label"] for r in rows], data.load_descriptions())
        print(f"описания есть у всех {len({r['label'] for r in rows})} меток корпуса")
    return 0


if __name__ == "__main__":
    sys.exit(main())
