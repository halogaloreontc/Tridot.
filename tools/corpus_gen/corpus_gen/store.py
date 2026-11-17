"""Файлы JSON Lines: кандидаты в work/, корпус в test/corpus/."""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Any, Callable, Iterable

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None  # type: ignore[assignment]
    import msvcrt

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
    # Одной записью: прерывание между строками не оставит половину пачки.
    text = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


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


# Как часто долгие команды (label, generate) сохраняют прогресс. Сохранение — полная
# атомарная перезапись candidates.jsonl (несколько тысяч строк, fsync): дешёвое, но не
# бесплатное, поэтому не после каждого ответа модели, а не чаще раза в SAVE_INTERVAL
# секунд и обязательно в конце или при прерывании. Теряется не больше нескольких секунд работы.
SAVE_INTERVAL = 5.0


class Checkpoint:
    """Периодическое сохранение фраз и расходов во время долгой команды.

    Потоки-исполнители меняют store.rows и копят строки расхода только под self.lock;
    сохранение тоже идёт под ним, поэтому файл никогда не пишется, пока другой поток
    меняет строки. После close() поздние ответы (запросы, брошенные при прерывании)
    отбрасываются: файл уже записан окончательно.
    """

    def __init__(
        self,
        store: CandidateStore,
        *,
        interval: float | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.store = store
        self.interval = SAVE_INTERVAL if interval is None else interval
        self.clock = clock
        self.lock = threading.Lock()
        self.closed = False
        self.saves = 0
        self._dirty = False
        self._usage: list[dict[str, Any]] = []
        self._last = clock()

    def changed(self) -> None:
        """Строки поменялись; вызывать под self.lock."""
        self._dirty = True

    def add_usage(self, row: dict[str, Any]) -> None:
        """Строка расхода; вызывать под self.lock."""
        self._usage.append(row)

    def maybe_save(self) -> bool:
        """Сохраняет, если есть изменения и с прошлого сохранения прошло interval секунд."""
        with self.lock:
            if self.clock() - self._last < self.interval:
                return False
            return self._save_locked()

    def flush(self, *, close: bool = False) -> bool:
        """Сохраняет несохранённое сейчас; close=True — последнее сохранение команды."""
        with self.lock:
            saved = self._save_locked()
            if close:
                self.closed = True
            return saved

    def _save_locked(self) -> bool:
        if not self._dirty and not self._usage:
            return False
        if self._usage:
            # Сначала забираем список, потом пишем: если сигнал прервёт запись после того,
            # как строки уже на диске, повторное сохранение не допишет их второй раз.
            rows, self._usage = self._usage, []
            self.store.record_usage(rows)
        if self._dirty:
            self.store.save()
            self._dirty = False
        self._last = self.clock()
        self.saves += 1
        return True


class LockedError(RuntimeError):
    """work/ занят другим процессом corpus-gen."""


class WorkLock:
    """work/.lock: два процесса corpus-gen не должны одновременно писать work/.

    Иначе последний сохранивший молча затрёт фразы и разметки другого. Блокировка —
    это блокировка ОС на открытом файле (flock), а не просто файл с PID: её держит
    ядро, пока жив процесс, и само снимает, когда процесс умер (упал, убит, сел
    аккумулятор). Поэтому брошенную блокировку не нужно угадывать по PID — нет ни
    гонки при её захвате, ни ложной «занятости» после перезагрузки, когда старый PID
    достался другой программе. PID в файле — только для сообщения об ошибке.
    """

    def __init__(self, work_dir: Path) -> None:
        self.path = work_dir / ".lock"
        self.held = False
        self._fd: int | None = None

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(10):
            fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
            if not _try_lock(fd):
                os.close(fd)
                owner = _lock_owner(self.path)
                who = f"PID {owner}" if owner is not None else "PID неизвестен"
                raise LockedError(
                    f"work/ занят другим процессом corpus-gen ({who}). Дождитесь его "
                    f"окончания или остановите его."
                )
            if not _same_file(fd, self.path):
                # Пока мы ждали, владелец снял блокировку и удалил файл; берём новый.
                os.close(fd)
                continue
            os.ftruncate(fd, 0)
            os.write(fd, f"{os.getpid()}\n".encode())
            self._fd = fd
            self.held = True
            return
        raise LockedError(f"Не удалось занять {self.path}: его одновременно занимает другой процесс.")

    def release(self) -> None:
        if self._fd is not None:
            # Удаляем файл, только пока держим блокировку и только свой: кто-то мог
            # заменить его новым — чужой файл не трогаем.
            if _same_file(self._fd, self.path):
                try:
                    self.path.unlink()
                except OSError:
                    pass  # Windows не удаляет открытый файл; пустой файл не мешает
            os.close(self._fd)  # закрытие снимает блокировку
            self._fd = None
        self.held = False

    def __enter__(self) -> WorkLock:
        self.acquire()
        return self

    def __exit__(self, *_: Any) -> None:
        self.release()


def _try_lock(fd: int) -> bool:
    try:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        else:  # Windows
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
    except OSError:
        return False
    return True


def _same_file(fd: int, path: Path) -> bool:
    try:
        on_disk = os.stat(path)
    except OSError:
        return False
    opened = os.fstat(fd)
    return (on_disk.st_dev, on_disk.st_ino) == (opened.st_dev, opened.st_ino)


def _lock_owner(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
