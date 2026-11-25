"""Выбор метки генеративной моделью: вывод ограничен списком меток.

Метки (и `none`) токенизируются и складываются в дерево. На каждом шаге
разрешены только продолжения из дерева; вероятность шага — softmax логитов
по разрешённым токенам. Жадный путь даёт метку, произведение вероятностей
шагов — уверенность. Без модели: тесты подставляют свои логиты.
"""

from __future__ import annotations

import math
from typing import Callable, Sequence

END = -1


class LabelTrie:
    def __init__(self, sequences: dict[str, Sequence[int]]):
        self.root: dict = {}
        for label, tokens in sequences.items():
            if not tokens:
                raise ValueError(f"пустая метка {label!r}")
            node = self.root
            for t in tokens:
                node = node.setdefault(t, {})
            if END in node:
                raise ValueError(f"метки {node[END]!r} и {label!r} токенизируются одинаково")
            node[END] = label


def choose(trie: LabelTrie, step: Callable[[Sequence[int]], Sequence[float]]) -> tuple[str, float]:
    """`step(prefix)` — логиты следующего токена после уже выбранных `prefix`."""
    node = trie.root
    prefix: list[int] = []
    logp = 0.0
    while True:
        options = [t for t in node if t != END]
        if not options:
            return node[END], math.exp(logp)
        if END in node:
            # Метка — префикс другой: такого в наших метках нет.
            raise ValueError(f"метка {node[END]!r} — префикс другой метки")
        if len(options) == 1:
            t = options[0]
        else:
            logits = step(prefix)
            vals = [float(logits[o]) for o in options]
            top = max(vals)
            z = sum(math.exp(v - top) for v in vals)
            best = max(range(len(options)), key=lambda i: vals[i])
            t = options[best]
            logp += vals[best] - top - math.log(z)
        prefix.append(t)
        node = node[t]
