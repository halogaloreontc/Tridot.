"""Выпуск «Продвинутой» (ADR-046): GGUF из официальных весов.

Шаги (запускать из корня репозитория):

  python -m tools.gen_model.release weights   # веса Qwen с закреплённой ревизией
  python -m tools.gen_model.release convert   # → bf16 GGUF (convert_hf_to_gguf.py)
  python -m tools.gen_model.release quantize --version 1.0.0   # → Q5_K_M
  python -m tools.gen_model.release verify --version 1.0.0     # проба таблиц
  python -m tools.gen_model.release split --version 1.0.0      # части до 2 ГиБ
  python -m tools.gen_model.release latest --version 1.0.0 --base-url URL

Части: GitHub не принимает файлы выпуска больше 2 ГиБ, а модель ~2,9 ГБ.
Приложение качает их по очереди и склеивает (у каждой — размер и sha256,
у целого файла — тоже).

`convert` идёт в окружении с torch и transformers (`.venv-intent`),
остальные — в `.venv-gen` (llama-cpp-python). Скрипт перевода и gguf-py —
из исходников llama.cpp той же версии, что и обёртка приложения
(`tool/fetch_llama.sh`). Результат — `out/release/`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from . import config

REPO_ID = "Qwen/Qwen3-4B-Instruct-2507"
REVISION = "cdbee75f17c01a7cc42f958dc650907174af0554"
LICENSE = "Apache-2.0"
TITLE = "Qwen3-4B-Instruct-2507"
QUANT = "Q5_K_M"
MIN_RAM_MB = 7000
# Не меньше стольких верных ответов из 24 на пробе таблиц — иначе выпуска
# нет. Замер своей сборки (2026-11-26): Q5_K_M — 24 из 24, Q4_K_M — 22
# (обе ошибки — сумма вместо количества); Q5_K_M на ~0,4 ГБ больше.
MIN_TABLES = 22

# Часть — меньше предела файла выпуска GitHub (2 ГиБ).
PART_BYTES = 1900 * 1024 * 1024

LLAMA = config.REPO / "third_party" / "llama.cpp"
OUT = config.OUT / "release"
WEIGHTS = config.CACHE / f"weights-{REVISION[:12]}"
BF16 = OUT / "model-bf16.gguf"


def gguf_name(version: str) -> str:
    return f"tridot-gen-{version}.gguf"


def weights() -> Path:
    from huggingface_hub import snapshot_download

    path = snapshot_download(
        REPO_ID,
        revision=REVISION,
        local_dir=WEIGHTS,
        allow_patterns=["*.json", "*.safetensors", "merges.txt", "vocab.json", "LICENSE"],
    )
    print(path)
    return Path(path)


def convert() -> Path:
    if not (LLAMA / "convert_hf_to_gguf.py").exists():
        raise SystemExit("нет исходников llama.cpp: tool/fetch_llama.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PYTHONPATH=str(LLAMA / "gguf-py"))
    subprocess.run(
        [sys.executable, str(LLAMA / "convert_hf_to_gguf.py"), str(WEIGHTS),
         "--outtype", "bf16", "--outfile", str(BF16)],
        check=True, env=env,
    )
    print(BF16)
    return BF16


def quantize(version: str) -> Path:
    import llama_cpp

    out = OUT / gguf_name(version)
    params = llama_cpp.llama_model_quantize_default_params()
    params.ftype = llama_cpp.LLAMA_FTYPE_MOSTLY_Q5_K_M
    params.nthread = config.THREADS
    rc = llama_cpp.llama_model_quantize(str(BF16).encode(), str(out).encode(), params)
    if rc != 0:
        raise SystemExit(f"квантование не удалось: {rc}")
    print(out)
    return out


def verify(version: str) -> dict:
    from .runner import Runner, sha256
    from . import tasks

    path = OUT / gguf_name(version)
    digest = sha256(path)
    m = config.Model(
        name="release", title=TITLE, repo=REPO_ID, revision=REVISION,
        file=path.name, sha256=digest, license=LICENSE,
    )
    old = config.CACHE
    config.CACHE = OUT
    try:
        runner = Runner(m)
    finally:
        config.CACHE = old
    ok = 0
    questions = tasks.read_jsonl("tables.jsonl")
    for q in questions:
        rows = tasks.load_table(q["table"])
        raw = runner.complete(tasks.table_system(rows), q["question"], tasks.table_schema(list(rows[0])))
        try:
            got = tasks.run_query(rows, json.loads(raw))
        except (json.JSONDecodeError, KeyError, TypeError):
            got = None
        ok += tasks.answer_ok(got, q["answer"])
    result = {
        "version": version, "file": path.name, "size": path.stat().st_size, "sha256": digest,
        "tables_correct": ok, "tables_total": len(questions), "min_tables": MIN_TABLES,
        "base_model": REPO_ID, "base_revision": REVISION, "quant": QUANT,
    }
    (OUT / "verify.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    if ok < MIN_TABLES:
        raise SystemExit(f"проба таблиц: {ok} из {len(questions)}, нужно не меньше {MIN_TABLES} — выпуска нет")
    return result


def split(version: str) -> list[dict]:
    from .runner import sha256

    v = json.loads((OUT / "verify.json").read_text(encoding="utf-8"))
    if v["version"] != version:
        raise SystemExit(f"verify.json — версия {v['version']}, а не {version}")
    src = OUT / v["file"]
    parts_dir = OUT / "parts"
    parts_dir.mkdir(parents=True, exist_ok=True)
    for old in parts_dir.iterdir():
        old.unlink()
    parts = []
    with open(src, "rb") as f:
        n = 0
        while block := f.read(PART_BYTES):
            n += 1
            part = parts_dir / f"{v['file']}.{n:03d}"
            part.write_bytes(block)
            parts.append({"file": part.name, "size": len(block), "sha256": sha256(part)})
    if sum(p["size"] for p in parts) != v["size"]:
        raise SystemExit("части не складываются в модель")
    (OUT / "parts.json").write_text(json.dumps(parts, ensure_ascii=False, indent=1), encoding="utf-8")
    for p in parts:
        print(parts_dir / p["file"])
    return parts


def latest(version: str, base_url: str, out: Path) -> dict:
    v = json.loads((OUT / "verify.json").read_text(encoding="utf-8"))
    if v["version"] != version:
        raise SystemExit(f"verify.json — версия {v['version']}, а не {version}")
    parts = json.loads((OUT / "parts.json").read_text(encoding="utf-8"))
    base = base_url.rstrip("/") + "/"
    data = {
        "format": "tridot-gen-latest/1",
        "version": version,
        "model": {
            "file": v["file"],
            "size": v["size"],
            "sha256": v["sha256"],
            "parts": [{"url": base + p["file"], "size": p["size"], "sha256": p["sha256"]} for p in parts],
            "title": TITLE,
            "license": LICENSE,
            "base_model": REPO_ID,
            "base_revision": v["base_revision"],
            "quant": v["quant"],
            "min_ram_mb": MIN_RAM_MB,
        },
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    print(out)
    return data


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("step", choices=["weights", "convert", "quantize", "verify", "split", "latest"])
    ap.add_argument("--version")
    ap.add_argument("--base-url")
    ap.add_argument("--out", type=Path, default=OUT / "latest.json")
    a = ap.parse_args(argv)
    if a.step in ("quantize", "verify", "split", "latest") and not a.version:
        raise SystemExit("нужна --version")
    if a.step == "weights":
        weights()
    elif a.step == "convert":
        convert()
    elif a.step == "quantize":
        quantize(a.version)
    elif a.step == "verify":
        verify(a.version)
    elif a.step == "split":
        split(a.version)
    else:
        if not a.base_url:
            raise SystemExit("нужен --base-url")
        latest(a.version, a.base_url, a.out)


if __name__ == "__main__":
    main()
