"""Согласие слоёв: ранжирование kNN и правило подсказки."""

import numpy as np

from tools.gen_model.agree import combine, ranked


def test_ranked_votes_by_similarity():
    train = np.array([[1, 0], [0.9, 0.1], [0, 1]], dtype=np.float32)
    train /= np.linalg.norm(train, axis=1, keepdims=True)
    r = ranked(train, ["a", "a", "b"], np.array([[1, 0]], dtype=np.float32), k=3)[0]
    assert [lab for lab, _ in r] == ["a", "b"]
    assert r[0][1] == 1.0


def test_combine_needs_agreement():
    rank = [("tasks:task.create", 0.93), ("alarm:alarm.set", 0.90), ("none", 0.88)]
    assert combine(rank, "alarm:alarm.set", 2) == {"pred": "alarm:alarm.set", "sim": 0.90, "second": None}
    assert combine(rank, "alarm:alarm.set", 1)["pred"] == "none"
    assert combine(rank, "none", 3)["pred"] == "none"
    assert combine(rank, "calc:calc.evaluate", 3)["pred"] == "none"
    assert combine(rank, "x", None)["pred"] == "tasks:task.create"
