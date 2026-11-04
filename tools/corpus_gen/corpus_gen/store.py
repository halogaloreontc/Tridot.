"""Файлы JSON Lines: кандидаты в work/, корпус в test/corpus/."""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Iterable

_SPACES = re.compile(r"\s+")
# Разделители строк Unicode и управляющие символы ломают JSON Lines у читателей,
# которые режут по ним строки; во фразах они не нужны.
_UNSAFE = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029\ufeff]")


def clean_phrase(text: str) -> str:
    return _UNSAFE.sub(" ", text).strip()


def normalize_text(text: str) -> str:
    """Ключ для поиска дублей: регистр, «ё» и пробелы не важны, кавычки важны."""
    return _SPACES.sub(" ", text.strip().lower().replace("ё", "е"))


def candidate_id(text: str) -> str:
    return hashlib.sha1(normalize_text(text).encode("utf-8")).hexdigest()[:12]


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows = []
    # Только "\n": str.splitlines() режет и по U+2028/U+0085 внутри JSON-строк.
    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{number}: {error}") from None
    return rows


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    """Атомарная перезапись: временный файл, fsync, rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def append_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def corpus_rows(corpus_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(corpus_dir.glob("*.jsonl")):
        rows.extend(read_jsonl(path))
    return rows


class CandidateStore:
    """work/candidates.jsonl — одна строка на фразу со всей историей разметки."""

    def __init__(self, work_dir: Path) -> None:
        self.path = work_dir / "candidates.jsonl"
        self.usage_path = work_dir / "usage.jsonl"
        self.rows: list[dict[str, Any]] = read_jsonl(self.path)

    def by_id(self) -> dict[str, dict[str, Any]]:
        return {row["cid"]: row for row in self.rows}

    def save(self) -> None:
        write_jsonl(self.path, self.rows)

    def record_usage(self, rows: list[dict[str, Any]]) -> None:
        if rows:
            append_jsonl(self.usage_path, rows)

    def usage(self) -> list[dict[str, Any]]:
        return read_jsonl(self.usage_path)
