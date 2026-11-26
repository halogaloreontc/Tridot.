"""Модель GGUF через llama-cpp-python: выбор метки и замер скорости.

Системный запрос с описаниями команд прогоняется один раз; перед каждой
фразой кэш обрезается до него (`Llama.eval` убирает всё после `n_tokens`).
"""

from __future__ import annotations

import hashlib
import os
import time

import numpy as np

from . import config, prompt
from .choose import LabelTrie, choose


def sha256(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def check(m: config.Model) -> None:
    if not m.path.exists():
        raise SystemExit(f"нет {m.path}: python -m tools.gen_model fetch --model {m.name}")
    got = sha256(m.path)
    if got != m.sha256:
        raise SystemExit(f"{m.file}: sha256 {got} ≠ {m.sha256}")


def rss_mb() -> float:
    import psutil

    return psutil.Process(os.getpid()).memory_info().rss / 1e6


class Runner:
    def __init__(self, m: config.Model, threads: int = config.THREADS):
        from llama_cpp import Llama

        check(m)
        self.model = m
        rss0 = rss_mb()
        started = time.perf_counter()
        self.llm = Llama(
            model_path=str(m.path),
            n_ctx=config.N_CTX,
            n_threads=threads,
            n_threads_batch=threads,
            n_batch=512,
            logits_all=False,
            verbose=False,
        )
        self.load_seconds = time.perf_counter() - started
        self.load_rss_mb = rss_mb() - rss0
        self.n_vocab = self.llm.n_vocab()
        self.eos = self.llm.tokenize(b"<|im_end|>", add_bos=False, special=True)
        if len(self.eos) != 1:
            raise SystemExit("в словаре нет <|im_end|> одним токеном")

    def _tok(self, text: str) -> list[int]:
        return self.llm.tokenize(text.encode("utf-8"), add_bos=False, special=True)

    def _logits(self) -> np.ndarray:
        ptr = self.llm._ctx.get_logits()
        return np.ctypeslib.as_array(ptr, shape=(self.n_vocab,)).copy()

    def prepare_labels(self, descriptions: dict[str, str], examples: dict[str, list[str]] | None = None) -> None:
        system = prompt.system_prompt(descriptions, examples)
        self.prefix = self._tok(prompt.chat_prefix(system))
        started = time.perf_counter()
        self.llm.reset()
        self.llm.eval(self.prefix)
        self.prefix_seconds = time.perf_counter() - started
        names = sorted(descriptions) + [prompt.NONE]
        self.trie = LabelTrie({n: self._tok(n) + self.eos for n in names})

    def choose(self, text: str) -> tuple[str, float]:
        self.llm.n_tokens = len(self.prefix)
        self.llm.eval(self._tok(prompt.chat_suffix(text, self.model.empty_think)))
        done: list[int] = []

        def step(path):
            new = list(path[len(done):])
            if new:
                self.llm.eval(new)
                done.extend(new)
            return self._logits()

        return choose(self.trie, step)

    def bench_generate(self, text: str, n: int = 64) -> dict:
        """Скорость разбора запроса и свободной генерации (жадно, n токенов)."""
        self.llm.reset()
        tokens = self._tok(
            "<|im_start|>user\n" + text + "<|im_end|>\n<|im_start|>assistant\n"
            + ("<think>\n\n</think>\n\n" if self.model.empty_think else "")
        )
        started = time.perf_counter()
        self.llm.eval(tokens)
        prompt_s = time.perf_counter() - started
        out = []
        started = time.perf_counter()
        for _ in range(n):
            t = int(np.argmax(self._logits()))
            if t == self.eos[0]:
                break
            out.append(t)
            self.llm.eval([t])
        gen_s = time.perf_counter() - started
        return {
            "prompt_tokens": len(tokens),
            "prompt_tok_per_s": round(len(tokens) / prompt_s, 1),
            "gen_tokens": len(out),
            "gen_tok_per_s": round(len(out) / gen_s, 1) if out else 0.0,
            "text": self.llm.detokenize(out).decode("utf-8", "replace"),
        }

    def complete(self, system: str, user: str, schema: dict | None = None, max_tokens: int = 200) -> str:
        """Ответ по ChatML, жадно; со `schema` — JSON под грамматикой."""
        import json

        from llama_cpp import LlamaGrammar

        think = "<think>\n\n</think>\n\n" if self.model.empty_think else ""
        text = (
            f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n"
            f"<|im_start|>assistant\n{think}"
        )
        grammar = LlamaGrammar.from_json_schema(json.dumps(schema), verbose=False) if schema else None
        out = self.llm.create_completion(
            text, max_tokens=max_tokens, temperature=0.0, grammar=grammar, stop=["<|im_end|>"]
        )
        return out["choices"][0]["text"].strip()

