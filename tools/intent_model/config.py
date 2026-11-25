"""Настройки сборки модели понимания (ADR-045): уровни, обучение, пороги.

Меняются здесь, а не флагами: что записано в репозитории, то и выпускается.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

PKG = Path(__file__).resolve().parent
REPO = PKG.parent.parent
EVAL_DIR = PKG / "eval"
AUG_DIR = PKG / "aug"
LABELS_YAML = PKG / "labels.yaml"
OUT = Path(os.environ.get("INTENT_MODEL_OUT", PKG / "out"))

# Формат пакета и индекса: приложение (шаг 2) читает только известный ему.
PACK_FORMAT = "tridot-intent/1"
LATEST_FORMAT = "tridot-intent-latest/1"
INDEX_MAGIC = b"TRIX"
INDEX_VERSION = 1

# kNN по примерам корпуса: k ближайших, голос — сходство.
K = 5
MAX_LEN = 64
# Сетка порогов уверенности (сходство лучшего примера победившей метки).
GRID = [round(0.70 + 0.005 * i, 3) for i in range(57)]  # 0.70 … 0.98

# Бюджет ошибок (решение владельца): неверных — не больше ~6 % подсказок,
# ложных тревог на фразах «не команда» — не больше 5 %. Порог выбирается
# на fresh, выпуск падает, если на всех трёх пробах бюджет превышен.
MAX_WRONG_OF_SUGGESTED = 6.0
MAX_FALSE_ALARM = 5.0

# Обучение SupCon: пакет — P меток по K фраз, температура TAU.
SEED = 0
BATCH_LABELS = 16
BATCH_PER_LABEL = 4
TAU = 0.05

# Наборы проверки и порядок: первый — для выбора порога, остальные — проверка.
EVAL_SETS = ("fresh", "held2", "held3")
DEV_SET = "fresh"

# Навыки, которые веб-помощник склада выполняет сам
# (lib/web_widget/widget_session.dart: описание склада, калькулятор, беседа).
WEB_CONNECTORS = ("warehouse", "calc", "talk")

# Складская проба веб-помощника (eval/warehouse.jsonl): речь кладовщика по
# командам склада, калькулятор, беседа и «не команды» со словами-приманками.
# Делится пополам (data.split_half): половина `cal` — в подбор порога веба
# вместе с fresh/held2/held3, половина `test` — только честная проверка.
WEB_SET = "warehouse"


@dataclass(frozen=True)
class Tier:
    name: str
    title: str
    base_model: str = ""
    revision: str = ""
    license: str = ""
    lr: float = 0.0
    epochs: float = 0.0
    prefix: str = ""
    per_channel: bool = False
    # Уровень без своей модели: берёт модель и пробы другого уровня,
    # индекс — только по своим меткам (остальные становятся «none»).
    model_from: str = ""
    connectors: tuple[str, ...] = field(default_factory=tuple)
    # Свои пробы уровня сверх EVAL_SETS (их holdout — на модели source).
    extra_sets: tuple[str, ...] = field(default_factory=tuple)
    # Уровень со своей моделью на основе другого: та же основа и обучение.
    base_from: str = ""
    # Дополнительные синтетические фразы обучения (aug/<имя>.jsonl).
    augment: tuple[str, ...] = field(default_factory=tuple)
    # Динамическое int8-квантование считает масштаб активаций по всему
    # тензору пакета (с паддингом), поэтому вектор фразы на CPU зависит от
    # соседей в пакете; на устройстве фраза кодируется одна. У USER-base
    # (accurate) это сдвигает вектор заметно (косинус bs=1 vs bs=32 — от
    # ~0,84), у прежней rubert-tiny2 — почти незаметно (от ~0,997). Включает
    # кодирование по одной фразе (без паддинга) в holdout/model/verify, чтобы
    # индекс и пробы совпадали с тем, что видит устройство.
    bs1_vectors: bool = False

    @property
    def source(self) -> str:
        """Уровень, чья модель обучается для этого пакета."""
        return self.model_from or self.name


TIERS: dict[str, Tier] = {
    # «Лёгкая» (rubert-tiny2) снята 2026-11-25: остались «Точная» и web.
    "accurate": Tier(
        name="accurate",
        title="Точная",
        base_model="deepvk/USER-base",
        revision="e8446472f6024df155a04b2f0911b6044cabc51f",
        license="Apache-2.0",
        lr=3e-5,
        epochs=3,
        # Подсказка модели для запросов (config_sentence_transformers.json,
        # default_prompt_name = query): и в обучении, и на устройстве.
        prefix="query: ",
        # int8 по каналам точнее для этой модели (сходства сдвигаются
        # меньше); порог всё равно подбирается на int8.
        per_channel=True,
        # Измерено (tools/intent_model/out/accurate/bs_compare.json):
        # с паддингом до 32 ложные тревоги 5,4–6,2 % — уже вне бюджета.
        bs1_vectors=True,
    ),
    "web": Tier(
        name="web",
        title="Веб-помощник",
        # Своя модель на основе «Точной» (USER-base, архив ~131 МБ):
        # корпус и синтетические перефразы команд склада
        # (aug/warehouse.jsonl). Прежняя основа — rubert-tiny2:
        # на складе она ловила заметно меньше, чем хотелось (решение
        # владельца, 2026-11-24). Уровень наследует от «Точной» lr,
        # эпохи, префикс «query: », поканальное int8 и bs1_vectors.
        base_from="accurate",
        connectors=WEB_CONNECTORS,
        extra_sets=(WEB_SET,),
        augment=(WEB_SET,),
    ),
}


def tier(name: str) -> Tier:
    if name not in TIERS:
        raise SystemExit(f"Неизвестный уровень {name!r}: {', '.join(TIERS)}")
    t = TIERS[name]
    if t.model_from or t.base_from:
        base = TIERS[t.model_from or t.base_from]
        return Tier(
            name=t.name,
            title=t.title,
            base_model=base.base_model,
            revision=base.revision,
            license=base.license,
            lr=base.lr,
            epochs=base.epochs,
            prefix=base.prefix,
            per_channel=base.per_channel,
            bs1_vectors=base.bs1_vectors,
            model_from=t.model_from,
            connectors=t.connectors,
            extra_sets=t.extra_sets,
            base_from=t.base_from,
            augment=t.augment,
        )
    return t


def holdout_sets(source: str) -> tuple[str, ...]:
    """Пробы, которые собирает holdout уровня source: общие и свои у тех,
    кто берёт его модель (web → ещё warehouse)."""
    extra = [s for t in TIERS.values() if (t.model_from or t.name) == source for s in t.extra_sets]
    return EVAL_SETS + tuple(dict.fromkeys(extra))


def tier_dir(name: str) -> Path:
    return OUT / name
