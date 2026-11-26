"""Выбор метки по дереву токенов — на поддельных логитах."""

import math

import pytest

from tools.gen_model import config
from tools.gen_model.choose import LabelTrie, choose
from tools.gen_model.prompt import NONE, chat_suffix, system_prompt

EOS = 9


def _logits(table):
    """Логиты по префиксу: словарь «префикс → {токен: логит}», остальное −∞."""

    def step(prefix):
        row = [-1e9] * 10
        for t, v in table.get(tuple(prefix), {}).items():
            row[t] = v
        return row

    return step


def test_greedy_path_and_confidence():
    trie = LabelTrie({"a": [1, EOS], "ab": [1, 2, EOS], "c": [3, EOS]})
    step = _logits({(): {1: 2.0, 3: 0.0}, (1,): {EOS: 0.0, 2: 1.0}})
    label, conf = choose(trie, step)
    assert label == "ab"
    p1 = math.exp(2) / (math.exp(2) + 1)
    p2 = math.exp(1) / (math.exp(1) + 1)
    assert conf == pytest.approx(p1 * p2)


def test_single_option_steps_are_free():
    calls = []

    def step(prefix):
        calls.append(tuple(prefix))
        return [0.0] * 10

    trie = LabelTrie({"x": [4, 5, 6, EOS], "y": [7, EOS]})
    label, conf = choose(trie, step)
    assert calls == [()]
    assert label == "x" and conf == pytest.approx(0.5)


def test_disallowed_tokens_do_not_count():
    trie = LabelTrie({"a": [1, EOS], "b": [2, EOS]})
    step = _logits({(): {1: 0.0, 2: 0.0, 5: 100.0}})
    assert choose(trie, step) == ("a", pytest.approx(0.5))


def test_same_tokens_rejected():
    with pytest.raises(ValueError):
        LabelTrie({"a": [1, EOS], "b": [1, EOS]})


def test_prompt_lists_every_label_and_none():
    text = system_prompt({"tasks:task.create": "создать задачу", "calc:calc.evaluate": "посчитать"})
    assert "tasks:task.create — создать задачу" in text
    assert f"{NONE} — " in text
    assert chat_suffix("x", empty_think=True).endswith("<think>\n\n</think>\n\n")
    assert chat_suffix("x", empty_think=False).endswith("<|im_start|>assistant\n")


def test_prompt_with_examples():
    text = system_prompt({"calc:calc.evaluate": "посчитать"}, {"calc:calc.evaluate": ["два плюс два"], "none": []})
    assert "Примеры фраз для меток:\ncalc:calc.evaluate: «два плюс два»\n" in text
    assert "none: " not in text.split("Примеры фраз")[1]
    assert "Примеры" not in system_prompt({"calc:calc.evaluate": "посчитать"})


def test_models_pinned():
    for m in config.MODELS.values():
        assert len(m.revision) == 40 and m.file.endswith(".gguf") and m.license == "Apache-2.0"
