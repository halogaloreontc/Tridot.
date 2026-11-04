"""Загрузка config.toml. Ключи API в файле не хранятся — только имена переменных окружения."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROLES = {"generate", "label"}
KINDS = {"anthropic", "openai_compat"}


@dataclass(frozen=True)
class Source:
    name: str
    kind: str
    family: str
    model: str
    roles: frozenset[str]
    base_url: str | None = None
    api_key_env: str | None = None
    effort: str | None = None
    fallbacks: str | None = None
    json_mode: bool = True
    max_tokens: int = 4000
    max_concurrency: int = 2
    requests_per_minute: int = 30
    price_in: float = 0.0
    price_out: float = 0.0
    enabled: bool = True

    def api_key(self) -> str | None:
        if not self.api_key_env:
            return None
        value = os.environ.get(self.api_key_env, "").strip()
        return value or None

    def unavailable_reason(self) -> str | None:
        """Почему источник нельзя использовать сейчас; None — можно."""
        if not self.enabled:
            return "выключен (enabled = false)"
        if self.api_key_env and self.api_key() is None:
            return f"нет переменной окружения {self.api_key_env}"
        if "<" in self.model:
            return f"не указана модель ({self.model})"
        return None

    def cost(self, input_tokens: int, output_tokens: int) -> float:
        return (input_tokens * self.price_in + output_tokens * self.price_out) / 1_000_000


@dataclass(frozen=True)
class Config:
    path: Path
    project_root: Path
    corpus_dir: Path
    work_dir: Path
    default_now: str
    dart: str
    sources: tuple[Source, ...] = field(default_factory=tuple)

    def source(self, name: str) -> Source:
        for source in self.sources:
            if source.name == name:
                return source
        raise KeyError(f"источник «{name}» не описан в {self.path}")

    def available(self, role: str) -> list[Source]:
        return [s for s in self.sources if role in s.roles and s.unavailable_reason() is None]


def load_config(path: Path) -> Config:
    path = path.resolve()
    with path.open("rb") as handle:
        raw = tomllib.load(handle)
    base = path.parent
    settings = raw.get("settings", {})
    project_root = (base / settings.get("project_root", "../..")).resolve()
    sources = tuple(_parse_source(item) for item in raw.get("source", []))
    names = [s.name for s in sources]
    duplicates = {n for n in names if names.count(n) > 1}
    if duplicates:
        raise ValueError(f"повторяющиеся имена источников: {sorted(duplicates)}")
    return Config(
        path=path,
        project_root=project_root,
        corpus_dir=(project_root / settings.get("corpus_dir", "test/corpus")).resolve(),
        work_dir=(base / settings.get("work_dir", "work")).resolve(),
        default_now=settings.get("default_now", "2026-11-02T16:30"),
        dart=settings.get("dart", "dart"),
        sources=sources,
    )


def _parse_source(item: dict) -> Source:
    name = item.get("name")
    if not name:
        raise ValueError("у источника нет name")
    kind = item.get("kind")
    if kind not in KINDS:
        raise ValueError(f"{name}: kind должен быть одним из {sorted(KINDS)}")
    roles = frozenset(item.get("roles", ["generate", "label"]))
    if not roles or not roles <= ROLES:
        raise ValueError(f"{name}: roles должны быть из {sorted(ROLES)}")
    if kind == "openai_compat" and not item.get("base_url"):
        raise ValueError(f"{name}: для openai_compat нужен base_url")
    return Source(
        name=name,
        kind=kind,
        family=item.get("family", name),
        model=item["model"],
        roles=roles,
        base_url=item.get("base_url"),
        api_key_env=item.get("api_key_env") or None,
        effort=item.get("effort"),
        fallbacks=item.get("fallbacks"),
        json_mode=item.get("json_mode", True),
        max_tokens=int(item.get("max_tokens", 4000)),
        max_concurrency=max(1, int(item.get("max_concurrency", 2))),
        requests_per_minute=max(1, int(item.get("requests_per_minute", 30))),
        price_in=float(item.get("price_in", 0.0)),
        price_out=float(item.get("price_out", 0.0)),
        enabled=bool(item.get("enabled", True)),
    )
