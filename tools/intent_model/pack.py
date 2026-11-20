"""Индекс, описания меток, манифест и архив пакета; latest.json выпуска.

Только numpy и стандартная библиотека.

index.bin (little-endian):
  0   4 байта  "TRIX"
  4   uint16   версия формата (1)
  6   uint16   0
  8   uint32   n — число примеров
  12  uint32   dims — размер вектора
  16  n×dims   float16 — нормированные векторы примеров
  …   n        uint16 — номер метки примера в labels.json → labels
"""

from __future__ import annotations

import hashlib
import json
import struct
import zipfile
from pathlib import Path
from typing import Sequence

import numpy as np

from . import config
from .model import TOKENIZER_FILES

__all__ = ["TOKENIZER_FILES", "write_index", "read_index", "write_labels", "make_pack", "latest"]


def write_index(path: Path, emb: np.ndarray, labels: Sequence[str]) -> list[str]:
    """Пишет индекс; возвращает список меток (порядок — номера в индексе)."""
    emb = np.asarray(emb, dtype=np.float16)
    if emb.ndim != 2 or emb.shape[0] != len(labels):
        raise ValueError(f"векторов {emb.shape}, меток {len(labels)}")
    names = sorted(set(labels), key=lambda x: (x != "none", x))  # none — номер 0
    if len(names) > 0xFFFF:
        raise ValueError("слишком много меток")
    num = {n: i for i, n in enumerate(names)}
    with path.open("wb") as fh:
        fh.write(config.INDEX_MAGIC)
        fh.write(struct.pack("<HHII", config.INDEX_VERSION, 0, emb.shape[0], emb.shape[1]))
        fh.write(emb.astype("<f2").tobytes())
        fh.write(np.array([num[x] for x in labels], dtype="<u2").tobytes())
    return names


def read_index(path: Path, labels_json: Path) -> tuple[np.ndarray, list[str]]:
    raw = path.read_bytes()
    if raw[:4] != config.INDEX_MAGIC:
        raise ValueError("не индекс TRIX")
    ver, _, n, dims = struct.unpack("<HHII", raw[4:16])
    if ver != config.INDEX_VERSION:
        raise ValueError(f"версия индекса {ver}")
    end = 16 + n * dims * 2
    if len(raw) != end + 2 * n:
        raise ValueError("длина индекса не сходится")
    emb = np.frombuffer(raw[16:end], dtype="<f2").reshape(n, dims).astype(np.float32)
    nums = np.frombuffer(raw[end:], dtype="<u2")
    names = [x["id"] for x in json.loads(labels_json.read_text(encoding="utf-8"))["labels"]]
    return emb, [names[i] for i in nums]


def write_labels(path: Path, names: Sequence[str], descriptions: dict[str, str]) -> None:
    labels = []
    for n in names:
        conn, _, cmd = n.partition(":")
        item = {"id": n}
        if n != "none":
            item.update({"connector": conn, "command": cmd, "description": descriptions[n]})
        labels.append(item)
    body = {"format": config.PACK_FORMAT, "question": "Похоже, вы хотите {description}?", "labels": labels}
    path.write_text(json.dumps(body, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_pack(
    pack_dir: Path,
    zip_path: Path,
    *,
    tier: config.Tier,
    version: str,
    info: dict,
    corpus_hash: str,
    metrics: dict,
) -> Path:
    """manifest.json и архив: model.int8.onnx, токенизатор, index.bin, labels.json."""
    need = ["model.int8.onnx", "index.bin", "labels.json", "tokenizer.json"]
    missing = [f for f in need if not (pack_dir / f).exists()]
    if missing:
        raise SystemExit(f"{pack_dir}: нет {', '.join(missing)}")
    files = sorted(p for p in pack_dir.iterdir() if p.is_file() and p.name != "manifest.json")
    honest = metrics.get("honest", {}).get("all", {})
    manifest = {
        "format": config.PACK_FORMAT,
        "tier": tier.name,
        "title": tier.title,
        "version": version,
        "base_model": tier.base_model,
        "base_revision": tier.revision,
        "base_license": tier.license,
        "threshold": metrics["threshold"],
        "k": metrics.get("k", config.K),
        "dims": info["dims"],
        "max_length": info["max_length"],
        "pooling": info["pooling"],
        "normalized": info.get("normalized", True),
        "inputs": info["inputs"],
        "output": info["output"],
        "prefix": tier.prefix,
        "connectors": list(tier.connectors),
        "corpus_hash": corpus_hash,
        "metrics": {
            "honest_catch": honest.get("catch"),
            "honest_catch_of_commands": honest.get("catch_of_commands"),
            "honest_wrong": honest.get("wrong"),
            "honest_wrong_of_suggested": honest.get("wrong_of_suggested"),
            "honest_false_alarm": honest.get("false_alarm"),
            "latency_ms_median": metrics.get("latency_ms", {}).get("1_thread", {}).get("median"),
        },
        "files": {p.name: {"size": p.stat().st_size, "sha256": sha256(p)} for p in files},
    }
    (pack_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    # Без сжатия модели (int8 почти не жмётся), время файлов постоянное —
    # архив одинаков при одинаковом содержимом.
    with zipfile.ZipFile(zip_path, "w") as z:
        for p in [*files, pack_dir / "manifest.json"]:
            zi = zipfile.ZipInfo(p.name, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_STORED if p.suffix == ".onnx" else zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            z.writestr(zi, p.read_bytes())
    return zip_path


def latest(version: str, base_url: str, zips: Sequence[Path]) -> dict:
    """latest.json выпуска: по уровню — адрес, размер, sha256 архива и главное из манифеста."""
    tiers = {}
    for z in zips:
        with zipfile.ZipFile(z) as f:
            m = json.loads(f.read("manifest.json"))
        if m.get("format") != config.PACK_FORMAT or m.get("version") != version:
            raise SystemExit(f"{z.name}: формат {m.get('format')}, версия {m.get('version')} — ожидалась {version}")
        tiers[m["tier"]] = {
            "url": f"{base_url.rstrip('/')}/{z.name}",
            "file": z.name,
            "size": z.stat().st_size,
            "sha256": sha256(z),
            "title": m["title"],
            "base_model": m["base_model"],
            "base_license": m["base_license"],
            "threshold": m["threshold"],
            "k": m["k"],
            "dims": m["dims"],
            "corpus_hash": m["corpus_hash"],
            "metrics": m["metrics"],
        }
    return {"format": config.LATEST_FORMAT, "version": version, "tiers": dict(sorted(tiers.items()))}
