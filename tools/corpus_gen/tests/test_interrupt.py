"""Прерывание и продолжение: сохранение по ходу работы, Ctrl+C, сигналы, work/.lock."""

from __future__ import annotations

import dataclasses
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

import pytest

from corpus_gen import cli, pipeline, store as store_module
from corpus_gen.providers import Completion
from corpus_gen.store import CandidateStore, Checkpoint, LockedError, WorkLock, read_jsonl

from test_pipeline import LABEL_CREATE, config_for, make_source, project  # noqa: F401
from test_single_labeler import FakeRouter, add_rows

TEXTS = [f"Добавь задачу «Дело {n}» завтра" for n in range(6)]


class CountingProvider:
    """Отвечает разметкой; вызов номер fail_at (общий счёт по всем источникам) — Ctrl+C."""

    def __init__(self, source: Any, shared: dict[str, Any]) -> None:
        self.source = source
        self.shared = shared

    def complete(self, system: str, user: str, schema: dict[str, Any]) -> Completion:
        with self.shared["lock"]:
            self.shared["calls"] += 1
            number = self.shared["calls"]
            self.shared["asked"].append((self.source.name, user))
        hook = self.shared.get("hook")
        if hook:
            hook(number)
        fail_at = self.shared.get("fail_at")
        if fail_at is not None and number >= fail_at:
            raise KeyboardInterrupt
        return Completion(dict(LABEL_CREATE), input_tokens=10, output_tokens=5)


def counting(fail_at: int | None = None, hook: Any = None) -> dict[str, Any]:
    return {"lock": threading.Lock(), "calls": 0, "asked": [], "fail_at": fail_at, "hook": hook}


def factory(shared: dict[str, Any]):
    return lambda source: CountingProvider(source, shared)


ONE = [make_source("ollama", "local"), make_source("gemma", "google")]
# Фразы от ollama (семейство local): размечает только gemma — задания идут строго по очереди.
SERIAL = [ONE[0], dataclasses.replace(ONE[1], max_concurrency=1)]


def saved_labels(config: Any) -> int:
    return sum(len(row["labels"]) for row in read_jsonl(config.work_dir / "candidates.jsonl"))


def test_interrupted_label_keeps_finished_labels_and_rerun_asks_only_missing(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, TEXTS)
    store.save()
    shared = counting(fail_at=4)

    with pytest.raises(pipeline.Interrupted) as stopped:
        pipeline.label(config, store, SERIAL, factory=factory(shared), router=FakeRouter())
    assert (stopped.value.saved, stopped.value.remaining) == (3, 3)

    rows = read_jsonl(config.work_dir / "candidates.jsonl")
    assert [bool(row["labels"]) for row in rows] == [True, True, True, False, False, False]
    assert {row["status"] for row in rows} == {"new"}  # статус решается только в конце
    assert len(read_jsonl(config.work_dir / "usage.jsonl")) == 3

    again = counting()
    counts = pipeline.label(
        config, CandidateStore(config.work_dir), SERIAL, factory=factory(again), router=FakeRouter()
    )
    assert again["calls"] == 3
    assert all("Дело 0" not in user for _, user in again["asked"])
    assert sum(counts[s] for s in ("agreed", "disputed")) == len(TEXTS)
    rows = read_jsonl(config.work_dir / "candidates.jsonl")
    assert all(row["labels"] for row in rows) and "new" not in {row["status"] for row in rows}
    assert len(read_jsonl(config.work_dir / "usage.jsonl")) == 6


def test_parallel_interrupt_then_rerun_requests_exactly_missing_labels(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    pipeline.import_manual(config, store, TEXTS, "web")  # семейство manual:web — по две разметки
    labelers = [make_source("a", "fa"), make_source("b", "fb")]
    with pytest.raises(pipeline.Interrupted):
        pipeline.label(config, store, labelers, factory=factory(counting(fail_at=5)), router=FakeRouter())

    rows = read_jsonl(config.work_dir / "candidates.jsonl")
    have = sum(len(row["labels"]) for row in rows)
    assert 1 <= have <= 4
    again = counting()
    pipeline.label(config, CandidateStore(config.work_dir), labelers, factory=factory(again), router=FakeRouter())
    assert again["calls"] == 2 * len(TEXTS) - have
    assert saved_labels(config) == 2 * len(TEXTS)


def test_progress_is_written_while_run_continues(project: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Без Ctrl+C (выключили питание): разметки уже на диске до конца запуска."""
    monkeypatch.setattr(store_module, "SAVE_INTERVAL", 0.0)
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, TEXTS)
    seen: list[int] = []

    def wait_for_disk(number: int) -> None:
        deadline = time.monotonic() + 5
        while saved_labels(config) < number - 1 and time.monotonic() < deadline:
            time.sleep(0.01)
        seen.append(saved_labels(config))

    shared = counting(hook=wait_for_disk)
    pipeline.label(config, store, SERIAL, factory=factory(shared), router=FakeRouter())
    assert seen == [0, 1, 2, 3, 4, 5]
    assert len(read_jsonl(config.work_dir / "usage.jsonl")) == len(TEXTS)


def test_sigterm_interrupts_like_ctrl_c_and_restores_handler(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, TEXTS)
    before = signal.getsignal(signal.SIGTERM)

    def terminate(number: int) -> None:
        if number == 3:
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(5)  # «зависший» запрос: ждать его не должны

    started = time.monotonic()
    with pytest.raises(pipeline.Interrupted) as stopped:
        pipeline.label(config, store, SERIAL, factory=factory(counting(hook=terminate)), router=FakeRouter())
    assert time.monotonic() - started < 3
    assert stopped.value.saved == 2
    assert saved_labels(config) == 2
    assert signal.getsignal(signal.SIGTERM) is before


def test_checkpoint_throttles_saves(tmp_path: Path) -> None:
    now = [100.0]
    store = CandidateStore(tmp_path)
    checkpoint = Checkpoint(store, interval=5.0, clock=lambda: now[0])
    assert not checkpoint.maybe_save()  # нечего сохранять
    with checkpoint.lock:
        store.rows.append({"cid": "1", "text": "a"})
        checkpoint.changed()
        checkpoint.add_usage({"source": "x"})
    now[0] = 104.9
    assert not checkpoint.maybe_save()
    assert not store.path.exists()
    now[0] = 105.0
    assert checkpoint.maybe_save()
    assert len(read_jsonl(store.path)) == 1 and len(read_jsonl(store.usage_path)) == 1
    with checkpoint.lock:
        store.rows.append({"cid": "2", "text": "b"})
        checkpoint.changed()
    now[0] = 106.0
    assert not checkpoint.maybe_save()
    assert checkpoint.flush(close=True)  # конец или прерывание — сразу
    assert len(read_jsonl(store.path)) == 2 and len(read_jsonl(store.usage_path)) == 1
    assert checkpoint.closed and checkpoint.saves == 2
    assert not checkpoint.flush()


def test_generate_saves_finished_batches_on_interrupt(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    calls = []

    class Generator:
        def __init__(self, source: Any) -> None:
            self.source = source

        def complete(self, system: str, user: str, schema: dict[str, Any]) -> Completion:
            calls.append(user)
            if len(calls) == 3:
                raise KeyboardInterrupt
            n = len(calls)
            return Completion({"phrases": [f"Создай задачу «Х{n}a»", f"Создай задачу «Х{n}b»"]}, 1, 1)

    with pytest.raises(pipeline.Interrupted) as stopped:
        pipeline.generate(config, store, "create", 8, [make_source("gen", "g")], per_request=2, factory=Generator)
    assert (stopped.value.saved, stopped.value.remaining) == (4, 2)
    assert len(read_jsonl(config.work_dir / "candidates.jsonl")) == 4
    assert len(read_jsonl(config.work_dir / "usage.jsonl")) == 2


def _dead_pid() -> int:
    process = subprocess.Popen([sys.executable, "-c", "pass"])
    process.wait()
    return process.pid


HOLDER = (
    "import sys, time; from pathlib import Path; from corpus_gen.store import WorkLock;"
    "lock = WorkLock(Path(sys.argv[1])); lock.acquire(); print('ok', flush=True); time.sleep(30)"
)


def _hold_lock(work_dir: Path) -> subprocess.Popen[str]:
    """Другой процесс corpus-gen, который держит work/.lock."""
    other = subprocess.Popen([sys.executable, "-c", HOLDER, str(work_dir)], stdout=subprocess.PIPE, text=True)
    assert other.stdout is not None and other.stdout.readline().strip() == "ok"
    return other


def test_work_lock_blocks_live_owner_and_takes_abandoned(tmp_path: Path) -> None:
    lock_path = tmp_path / ".lock"
    other = _hold_lock(tmp_path)
    try:
        with pytest.raises(LockedError, match=f"другим процессом corpus-gen \\(PID {other.pid}\\)"):
            WorkLock(tmp_path).acquire()
        assert lock_path.read_text().strip() == str(other.pid)
    finally:
        other.kill()
        other.wait()

    # Владелец убит (как при севшем аккумуляторе): файл остался, но блокировку сняла ОС.
    assert lock_path.exists()
    with WorkLock(tmp_path):
        assert lock_path.read_text().strip() == str(os.getpid())
    assert not lock_path.exists()

    lock_path.write_text("мусор")
    lock = WorkLock(tmp_path)
    lock.acquire()
    lock_path.unlink()
    lock_path.write_text("999999999\n")  # чужой новый файл: release его не трогает
    lock.release()
    assert lock_path.read_text() == "999999999\n"


def test_work_lock_ignores_pid_left_from_before_reboot(tmp_path: Path) -> None:
    """После перезагрузки PID из старого .lock может принадлежать живой чужой программе."""
    lock_path = tmp_path / ".lock"
    for stale in ("1", str(os.getppid()), str(_dead_pid())):
        lock_path.write_text(f"{stale}\n")
        with WorkLock(tmp_path):
            assert lock_path.read_text().strip() == str(os.getpid())


RACER = (
    "import sys, time; from pathlib import Path; from corpus_gen.store import WorkLock, LockedError;"
    "lock = WorkLock(Path(sys.argv[1])); start = float(sys.argv[2])\n"
    "while time.time() < start: pass\n"
    "try:\n lock.acquire()\nexcept LockedError:\n print('busy', flush=True)\n"
    "else:\n print('held', flush=True); time.sleep(0.5)"
)


def test_work_lock_abandoned_takeover_has_single_winner(tmp_path: Path) -> None:
    for _ in range(5):
        (tmp_path / ".lock").write_text(f"{_dead_pid()}\n")
        start = time.time() + 0.5
        racers = [
            subprocess.Popen([sys.executable, "-c", RACER, str(tmp_path), str(start)], stdout=subprocess.PIPE, text=True)
            for _ in range(4)
        ]
        results = [racer.communicate(timeout=20)[0].strip() for racer in racers]
        assert sorted(results) == ["busy", "busy", "busy", "held"]


def test_cli_refuses_second_process_but_allows_read_only(
    project: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config = config_for(project)
    config_path = str(project / "tools" / "corpus_gen" / "config.toml")
    config.work_dir.mkdir(parents=True, exist_ok=True)
    other = _hold_lock(config.work_dir)
    try:
        assert cli.main(["--config", config_path, "relabel"]) == 2
        assert "work/ занят другим процессом corpus-gen" in capsys.readouterr().err
        assert cli.main(["--config", config_path, "stats"]) == 0
    finally:
        other.kill()
        other.wait()


def test_second_signal_during_final_save_is_ignored(project: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Закрытие терминала шлёт два SIGHUP; второй не должен убить процесс до сохранения."""
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, TEXTS)
    before = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)}
    real_final_save = pipeline._final_save
    seen: list[Any] = []

    def final_save(checkpoint: Checkpoint) -> None:
        # Здесь раньше уже стояли прежние обработчики (SIG_DFL), и второй SIGHUP убивал процесс.
        handlers = [signal.getsignal(number) for number in before]
        seen.append(handlers)
        if all(handler is signal.SIG_IGN for handler in handlers):
            os.kill(os.getpid(), signal.SIGHUP)
            os.kill(os.getpid(), signal.SIGTERM)
        real_final_save(checkpoint)

    def hang_up(number: int) -> None:
        if number == 3:
            os.kill(os.getpid(), signal.SIGHUP)
            time.sleep(5)

    monkeypatch.setattr(pipeline, "_final_save", final_save)
    with pytest.raises(pipeline.Interrupted) as stopped:
        pipeline.label(config, store, SERIAL, factory=factory(counting(hook=hang_up)), router=FakeRouter())
    assert seen == [[signal.SIG_IGN] * 3]
    assert stopped.value.saved == 2 and saved_labels(config) == 2
    assert {number: signal.getsignal(number) for number in before} == before


def test_signal_after_usage_write_does_not_count_twice(project: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, TEXTS)
    monkeypatch.setattr(store_module, "SAVE_INTERVAL", 0.0)
    real_append = store_module.append_jsonl
    calls = [0]

    def append(path: Path, rows: Any) -> None:
        real_append(path, rows)
        calls[0] += 1
        if calls[0] == 2:
            raise KeyboardInterrupt  # сигнал сразу после write(): строки уже на диске

    def slow(_: int) -> None:
        time.sleep(0.15)  # главный поток успевает сохранить после каждого ответа

    monkeypatch.setattr(store_module, "append_jsonl", append)
    with pytest.raises(pipeline.Interrupted) as stopped:
        pipeline.label(config, store, SERIAL, factory=factory(counting(hook=slow)), router=FakeRouter())
    usage = read_jsonl(config.work_dir / "usage.jsonl")
    assert len(usage) == stopped.value.saved == saved_labels(config)


def test_cli_label_interrupt_message_exit_code_and_lock_release(
    project: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    config = config_for(project)

    def interrupted(*_: Any, **__: Any) -> Any:
        assert (config.work_dir / ".lock").exists()
        raise pipeline.Interrupted(7, 5)

    monkeypatch.setattr(pipeline, "label", interrupted)
    code = cli.main(["--config", str(project / "tools" / "corpus_gen" / "config.toml"), "label"])
    err = capsys.readouterr().err
    assert code == cli.INTERRUPTED_EXIT
    assert "Разметок сохранено за этот запуск: 7, осталось запросов: 5" in err
    assert "Запустите `corpus-gen label` ещё раз" in err
    assert not (config.work_dir / ".lock").exists()
