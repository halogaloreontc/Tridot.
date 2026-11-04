"""Единый интерфейс к моделям: Anthropic SDK и OpenAI-совместимые API (Ollama, Kimi, DeepSeek, Qwen, Grok, OpenAI)."""

from __future__ import annotations

import json
import re
import threading
import time
from dataclasses import dataclass
from typing import Any, Protocol

from .config import Source


@dataclass(frozen=True)
class Completion:
    data: dict[str, Any]
    input_tokens: int = 0
    output_tokens: int = 0


class ProviderError(RuntimeError):
    """Ответ модели нельзя использовать: отказ, обрезка, не-JSON.

    Токены оплаченного, но непригодного ответа сохраняются, чтобы попасть в расход.
    """

    def __init__(self, message: str, input_tokens: int = 0, output_tokens: int = 0) -> None:
        super().__init__(message)
        self.input_tokens = input_tokens
        self.output_tokens = output_tokens


class Provider(Protocol):
    source: Source

    def complete(self, system: str, user: str, schema: dict[str, Any]) -> Completion: ...


class RateLimiter:
    """Не чаще requests_per_minute запросов в минуту на источник."""

    def __init__(self, per_minute: int) -> None:
        self._interval = 60.0 / per_minute
        self._lock = threading.Lock()
        self._next = 0.0

    def wait(self) -> None:
        with self._lock:
            now = time.monotonic()
            delay = self._next - now
            self._next = max(now, self._next) + self._interval
        if delay > 0:
            time.sleep(delay)


class AnthropicProvider:
    def __init__(self, source: Source) -> None:
        import anthropic

        self.source = source
        self._anthropic = anthropic
        self._client = anthropic.Anthropic(api_key=source.api_key())
        self._limiter = RateLimiter(source.requests_per_minute)

    def complete(self, system: str, user: str, schema: dict[str, Any]) -> Completion:
        self._limiter.wait()
        output_config: dict[str, Any] = {"format": {"type": "json_schema", "schema": schema}}
        if self.source.effort:
            output_config["effort"] = self.source.effort
        request: dict[str, Any] = {
            "model": self.source.model,
            "max_tokens": self.source.max_tokens,
            "system": system,
            "messages": [{"role": "user", "content": user}],
            "output_config": output_config,
        }
        if self.source.fallbacks:
            # Серверный запасной маршрут при отказе модели (Sonnet 5.5 и старше).
            response = self._client.beta.messages.create(
                **request,
                betas=["server-side-fallback-2026-07-01"],
                fallbacks=self.source.fallbacks,
            )
        else:
            response = self._client.messages.create(**request)

        usage = response.usage
        tokens = (
            getattr(usage, "input_tokens", 0) or 0,
            getattr(usage, "output_tokens", 0) or 0,
        )
        if response.stop_reason == "refusal":
            details = getattr(response, "stop_details", None)
            category = getattr(details, "category", None)
            raise ProviderError(f"{self.source.name}: модель отказалась (category={category})", *tokens)
        if response.stop_reason == "max_tokens":
            raise ProviderError(f"{self.source.name}: ответ обрезан по max_tokens", *tokens)
        # При серверном fallback ответ отказавшейся модели идёт до блока
        # type="fallback", ответ запасной — после последнего такого блока.
        blocks = list(response.content)
        last_fallback = max((i for i, b in enumerate(blocks) if b.type == "fallback"), default=-1)
        text = "".join(b.text for b in blocks[last_fallback + 1 :] if b.type == "text")
        if not text:
            raise ProviderError(f"{self.source.name}: в ответе нет текста", *tokens)
        return Completion(_load_json(text, self.source.name, tokens), *tokens)


class OpenAICompatProvider:
    def __init__(self, source: Source) -> None:
        import openai

        self.source = source
        # Ollama не требует ключа, но клиент ожидает непустую строку.
        self._client = openai.OpenAI(base_url=source.base_url, api_key=source.api_key() or "local")
        self._limiter = RateLimiter(source.requests_per_minute)

    def complete(self, system: str, user: str, schema: dict[str, Any]) -> Completion:
        self._limiter.wait()
        # json_object не проверяет схему, поэтому схема передаётся текстом,
        # а ответ проверяется после разбора.
        prompt = (
            f"{user}\n\nОтветь ТОЛЬКО одним JSON-объектом по этой JSON Schema, без пояснений:\n"
            f"{json.dumps(schema, ensure_ascii=False)}"
        )
        request: dict[str, Any] = {
            "model": self.source.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
        }
        if self.source.json_mode:
            request["response_format"] = {"type": "json_object"}
        response = self._client.chat.completions.create(**request)
        usage = response.usage
        tokens = (
            getattr(usage, "prompt_tokens", 0) or 0,
            getattr(usage, "completion_tokens", 0) or 0,
        )
        if not response.choices:
            raise ProviderError(f"{self.source.name}: пустой ответ", *tokens)
        choice = response.choices[0]
        if choice.finish_reason == "length":
            raise ProviderError(f"{self.source.name}: ответ обрезан по длине", *tokens)
        text = choice.message.content or ""
        return Completion(_load_json(text, self.source.name, tokens), *tokens)


_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$", re.MULTILINE)


def _load_json(text: str, name: str, tokens: tuple[int, int] = (0, 0)) -> dict[str, Any]:
    """Разбирает JSON-объект, допуская markdown-ограждение и текст вокруг."""
    cleaned = _FENCE.sub("", text.strip()).strip()
    try:
        value = json.loads(cleaned)
    except json.JSONDecodeError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start == -1 or end <= start:
            raise ProviderError(f"{name}: ответ не JSON: {text[:200]!r}", *tokens) from None
        try:
            value = json.loads(cleaned[start : end + 1])
        except json.JSONDecodeError as error:
            raise ProviderError(f"{name}: ответ не JSON: {error}", *tokens) from None
    if not isinstance(value, dict):
        raise ProviderError(f"{name}: ожидался JSON-объект", *tokens)
    return value


def make_provider(source: Source) -> Provider:
    if source.kind == "anthropic":
        return AnthropicProvider(source)
    if source.kind == "openai_compat":
        return OpenAICompatProvider(source)
    raise ValueError(f"неизвестный kind: {source.kind}")
