"""Запрос «подсказка при «не понял»» для генеративной модели (ADR-046).

В запросе — описания команд из `tools/intent_model/labels.yaml` и, по
желанию, несколько фраз на команду из снимка корпуса до разбора пробы (как
у «Лёгкой»: утечки нет). Шаблон — ChatML (Qwen2.5, Qwen3).
"""

from __future__ import annotations

NONE = "none"
NONE_DESCRIPTION = "ни одна команда не подходит: это не просьба к помощнику или такой команды нет"

SYSTEM = """Ты — разборщик фраз офлайн-помощника «Связной». Пользователь написал фразу, которую правила помощника не поняли. Определи, какую команду он, скорее всего, имел в виду.

Команды (метка — что делает):
{commands}

{examples}Ответь одной меткой из списка, без пояснений. Если ни одна команда не подходит, ответь {none}."""


def system_prompt(descriptions: dict[str, str], examples: dict[str, list[str]] | None = None) -> str:
    lines = [f"{label} — {text}" for label, text in sorted(descriptions.items())]
    lines.append(f"{NONE} — {NONE_DESCRIPTION}")
    shots = ""
    if examples:
        rows = [f"{label}: " + "; ".join(f"«{t}»" for t in texts) for label, texts in sorted(examples.items()) if texts]
        shots = "Примеры фраз для меток:\n" + "\n".join(rows) + "\n\n"
    return SYSTEM.format(commands="\n".join(lines), none=NONE, examples=shots)


def chat_prefix(system: str) -> str:
    return f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n"


def chat_suffix(text: str, empty_think: bool) -> str:
    think = "<think>\n\n</think>\n\n" if empty_think else ""
    return f"Фраза: {text}<|im_end|>\n<|im_start|>assistant\n{think}"
