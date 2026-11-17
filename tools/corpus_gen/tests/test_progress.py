"""Индикатор прогресса разметки: строка в stderr, не чаще раза в 30 секунд."""

from __future__ import annotations

import io
from pathlib import Path

from corpus_gen import pipeline
from corpus_gen.cli import ProgressLine
from corpus_gen.store import CandidateStore

from test_interrupt import SERIAL, TEXTS, counting, factory
from test_pipeline import config_for, project  # noqa: F401
from test_single_labeler import FakeRouter, add_rows


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def test_progress_line_throttles_and_estimates_remaining_time() -> None:
    clock, out = Clock(), io.StringIO()
    line = ProgressLine("Разметка", clock=clock, stream=out)
    line(0, 400)
    clock.now = 10
    line(5, 400)  # раньше 30 секунд — молчим
    clock.now = 60
    line(100, 400)
    clock.now = 70
    line(400, 400)  # конец показываем всегда
    assert out.getvalue().splitlines() == [
        "Разметка: 0 из 400 (0%)",
        "Разметка: 100 из 400 (25%), осталось ≈ 3 мин",
        "Разметка: 400 из 400 (100%)",
    ]


def test_progress_line_formats_hours() -> None:
    clock, out = Clock(), io.StringIO()
    line = ProgressLine("Разметка", clock=clock, stream=out)
    line(0, 300)
    clock.now = 3600
    line(100, 300)
    assert out.getvalue().splitlines()[-1] == "Разметка: 100 из 300 (33%), осталось ≈ 2 ч 0 мин"


def test_label_reports_progress_up_to_all_jobs(project: Path) -> None:
    config = config_for(project)
    store = CandidateStore(config.work_dir)
    add_rows(config, store, TEXTS)
    seen: list[tuple[int, int]] = []
    pipeline.label(
        config, store, SERIAL, factory=factory(counting()), router=FakeRouter(), on_progress=lambda d, t: seen.append((d, t))
    )
    assert seen and seen[-1] == (len(TEXTS), len(TEXTS))
    assert all(t == len(TEXTS) for _, t in seen)
    assert [d for d, _ in seen] == sorted(d for d, _ in seen)
