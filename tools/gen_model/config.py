"""Модели-кандидаты «Продвинутой» и настройки замеров (ADR-046, шаг 1).

Меняются здесь, а не флагами: что записано в репозитории, то и мерилось.
Файлы GGUF — Q4_K_M, ревизия закреплена коммитом, sha256 сверяется после
загрузки. Для выпуска GGUF соберётся из официальных весов (шаг выпуска);
здесь — готовые квантования для сравнения моделей.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

PKG = Path(__file__).resolve().parent
REPO = PKG.parent.parent
OUT = Path(os.environ.get("GEN_MODEL_OUT", PKG / "out"))
CACHE = Path(os.environ.get("GEN_MODEL_CACHE", Path.home() / ".cache" / "tridot-gen"))

N_CTX = 8192
THREADS = int(os.environ.get("GEN_MODEL_THREADS", os.cpu_count() or 4))

# Порог уверенности подсказки: вероятность выбранной метки при выводе,
# ограниченном списком меток (произведение шагов, перенормированных по
# разрешённым токенам).
GRID = [round(0.30 + 0.01 * i, 2) for i in range(70)]  # 0.30 … 0.99


@dataclass(frozen=True)
class Model:
    name: str
    title: str
    repo: str
    revision: str
    file: str
    sha256: str
    license: str
    # «Размышления» Qwen3: пустой блок <think> в начале ответа выключает их.
    empty_think: bool = False

    @property
    def path(self) -> Path:
        return CACHE / self.file

    @property
    def url(self) -> str:
        return f"https://huggingface.co/{self.repo}/resolve/{self.revision}/{self.file}"


MODELS: dict[str, Model] = {
    "qwen3-1.7b": Model(
        name="qwen3-1.7b",
        title="Qwen3-1.7B",
        repo="unsloth/Qwen3-1.7B-GGUF",
        revision="d7f544eead698dbd1f15126ef60b45a1e1933222",
        file="Qwen3-1.7B-Q4_K_M.gguf",
        sha256="b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
        license="Apache-2.0",
        empty_think=True,
    ),
    "qwen2.5-1.5b": Model(
        name="qwen2.5-1.5b",
        title="Qwen2.5-1.5B-Instruct",
        repo="Qwen/Qwen2.5-1.5B-Instruct-GGUF",
        revision="91cad51170dc346986eccefdc2dd33a9da36ead9",
        file="qwen2.5-1.5b-instruct-q4_k_m.gguf",
        sha256="6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
        license="Apache-2.0",
    ),
    "qwen3-4b": Model(
        name="qwen3-4b",
        title="Qwen3-4B-Instruct-2507",
        repo="unsloth/Qwen3-4B-Instruct-2507-GGUF",
        revision="a06e946bb6b655725eafa393f4a9745d460374c9",
        file="Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        sha256="3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        license="Apache-2.0",
    ),
}


def model(name: str) -> Model:
    if name not in MODELS:
        raise SystemExit(f"неизвестная модель {name!r}; есть: {', '.join(MODELS)}")
    return MODELS[name]
