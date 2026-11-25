"""Корпус → размеченные фразы, пробы проверки, описания меток.

Только стандартная библиотека и PyYAML: шаг подготовки и его тесты не
тянут torch и не скачивают модели.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path
from typing import Iterable, Iterator

from . import config

# Задачи в корпусе размечены намерениями разбора, в пробах — id команды.
TASK_INTENTS = {
    "createTask": "task.create",
    "listTasks": "task.list",
    "completeTask": "task.complete",
    "rescheduleTask": "task.reschedule",
    "rescheduleMany": "task.rescheduleMany",
    "completeMany": "task.completeMany",
}

# Навык «Пароли» и приватные фразы модель не видит никогда (ADR-045):
# ни в обучении, ни в проверке, ни на устройстве.
PRIVATE_CONNECTORS = {"passwords"}

# Те же слова, что у PasswordPhrases.looksLike / CommandSuggester.isPrivate
# (lib/core/skills/passwords/passwords_phrases.dart). Здесь — с запасом:
# лишняя отсеянная фраза ничего не портит. На устройстве решает Dart.
_PRIVATE = re.compile(
    r"(?<![a-zа-яё])(?:"
    r"парол|пасвор|пассвор|password|пасс(?![a-zа-яё])|логин|login|"
    r"пин(?:а|у|ом)?(?![a-zа-яё])|пин-?код|pin(?![a-z])|pin-?code|cvv|cvc|"
    r"кодов(?:ое|ого|ым|ом)\s+слов|"
    r"код(?:а|у|ом|ы|ов)?\s+(?:от|для|к|ко|доступа|сейфа|домофона|"
    r"подъезда|двери|калитки|замка|карты|карточки|восстановления|"
    r"подтверждения|безопасности|из\s+смс|смс|входа)(?![a-zа-яё])"
    r")",
    re.IGNORECASE,
)


# Голое время («7:30», «в 9», «нет, на 6:45») — веб-уровень до модели не
# пускает (lib/core/intent/bare_time.dart, тот же разбор): без разговора о
# будильнике это не команда, а модель путала его с калькулятором.
_BARE_TIME = re.compile(
    r"^(?:(?:да|нет|ну|ок|давай|лучше)[,\s]+)?"
    r"(?P<pre>(?:часам\s+к|около|после|в|к|на|до|с)\s+)?"
    r"(?:[01]?\d|2[0-3])(?P<min>:[0-5]\d)?"
    r"(?:\s+(?P<suf>утра|вечера|дня|ночи|часов|часа|ч))?[.!?]?$"
)


def bare_time(text: str) -> bool:
    m = _BARE_TIME.match(text.lower().strip())
    return bool(m and (m.group("pre") or m.group("min") or m.group("suf")))


def is_private(text: str) -> bool:
    return bool(_PRIVATE.search(text.lower().replace("ё", "е"))) or "•" in text


def norm(text: str) -> str:
    s = text.lower().replace("ё", "е")
    s = re.sub(r"[^\w\s]", " ", s)
    return " ".join(s.split())


def corpus_label(row: dict) -> str | None:
    """Метка строки корпуса: `<навык>:<команда>`, `none` или None (не учим).

    None — строка без ясной метки: известный пробел, реплика с контекстом
    (`after`), «не понял» с маршрутом в навык, навык «Пароли» и приватные
    фразы.
    """
    if row.get("status") == "known_gap" or row.get("after"):
        return None
    conn = row.get("connector") or "tasks"
    intent = row.get("intent", "")
    if conn in PRIVATE_CONNECTORS or row.get("route") in PRIVATE_CONNECTORS:
        return None
    if is_private(row.get("text", "")):
        return None
    if intent == "unknown":
        # «не понял» с маршрутом в навык — у фразы нет команды, метка неясна.
        return "none" if row.get("route") in ("none", "ambiguous") else None
    if conn == "tasks":
        return "tasks:" + TASK_INTENTS.get(intent, intent)
    return f"{conn}:{intent}"


def skip_reason(row: dict) -> str:
    if row.get("status") == "known_gap":
        return "skip_known_gap"
    if row.get("after"):
        return "skip_after_context"
    conn = row.get("connector") or "tasks"
    if conn in PRIVATE_CONNECTORS or row.get("route") in PRIVATE_CONNECTORS:
        return "skip_private_skill"
    if is_private(row.get("text", "")):
        return "skip_private_text"
    return "skip_unclear_route"


def parse_lines(lines: Iterable[str]) -> Iterator[dict]:
    for line in lines:
        line = line.strip()
        if line and not line.startswith("//"):
            yield json.loads(line)


def corpus_files(rev: str | None = None, repo: Path = config.REPO) -> Iterator[tuple[str, list[str]]]:
    """Файлы test/corpus/*.jsonl рабочей копии или ревизии `rev` (git show)."""
    if rev is None:
        for f in sorted((repo / "test" / "corpus").glob("*.jsonl")):
            yield f.name, f.read_text(encoding="utf-8").splitlines()
        return
    names = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "--name-only", rev, "test/corpus/"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    for n in sorted(x for x in names if x.endswith(".jsonl")):
        text = subprocess.run(
            ["git", "-C", str(repo), "show", f"{rev}:{n}"],
            capture_output=True, text=True, check=True,
        ).stdout
        yield Path(n).name, text.splitlines()


def aug_files(names: Iterable[str]) -> Iterator[tuple[str, list[str]]]:
    """Синтетические фразы обучения уровня (aug/<имя>.jsonl), формат корпуса."""
    for n in names:
        yield f"aug/{n}.jsonl", (config.AUG_DIR / f"{n}.jsonl").read_text(encoding="utf-8").splitlines()


def train_files(augment: Iterable[str] = (), rev: str | None = None) -> list[tuple[str, list[str]]]:
    """Корпус (рабочая копия или ревизия) и синтетика уровня из рабочей копии."""
    return [*corpus_files(rev), *aug_files(augment)]


def jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def prepare(
    files: Iterable[tuple[str, list[str]]],
    leak_texts: Iterable[str] = (),
) -> tuple[list[dict], dict]:
    """Обучающие фразы из файлов корпуса и счётчики.

    leak_texts — фразы проб: строки корпуса, совпадающие с ними или почти
    совпадающие (жаккар по словам ≥ 0,8), убираются (утечка). Дубликаты
    (тот же текст после нормализации и та же метка) — один раз.
    """
    stats: Counter = Counter()
    leak = [(norm(t), set(norm(t).split())) for t in leak_texts]
    exact = {n for n, _ in leak}
    seen: set = set()
    rows: list[dict] = []
    for fname, lines in files:
        for o in parse_lines(lines):
            stats["corpus_rows"] += 1
            label = corpus_label(o)
            if label is None:
                stats[skip_reason(o)] += 1
                continue
            n = norm(o["text"])
            if leak and (n in exact or any(jaccard(set(n.split()), t) >= 0.8 for _, t in leak)):
                stats["removed_leak"] += 1
                continue
            key = (n, label)
            if key in seen:
                stats["dup_in_corpus"] += 1
                continue
            seen.add(key)
            rows.append({"id": o["id"], "text": o["text"], "label": label, "file": fname})
    stats["train_rows"] = len(rows)
    stats["train_labels"] = len({r["label"] for r in rows})
    return rows, dict(stats)


def restrict(label: str, connectors: Iterable[str]) -> str:
    """Метка уровня с ограниченным набором навыков: чужая — `none`."""
    conns = set(connectors)
    if not conns or label == "none":
        return label
    return label if label.split(":", 1)[0] in conns else "none"


def corpus_hash(rows: list[dict]) -> str:
    """sha256 обучающего набора (текст и метка), не зависит от порядка файлов."""
    h = hashlib.sha256()
    for line in sorted(f"{r['label']}\t{r['text']}" for r in rows):
        h.update(line.encode("utf-8") + b"\n")
    return h.hexdigest()


# --- пробы


def snapshots() -> dict:
    return json.loads((config.EVAL_DIR / "snapshots.json").read_text(encoding="utf-8"))


def load_eval(name: str, connectors: Iterable[str] = ()) -> list[dict]:
    """Проба `name` без приватных фраз; для веб-уровня — с чужими метками как `none`."""
    out = []
    conns = tuple(connectors)
    for o in parse_lines((config.EVAL_DIR / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()):
        if is_private(o["text"]) or o["label"].split(":", 1)[0] in PRIVATE_CONNECTORS:
            continue
        o["set"] = name
        o["split_key"] = o["label"]
        if conns:
            o["label"] = restrict(o["label"], conns)
            o["alt"] = sorted({restrict(a, conns) for a in o.get("alt", [])} - {o["label"]})
            o["rule_label"] = restrict(o.get("rule_label", "none"), conns)
        out.append(o)
    return out


def split_half(evals: list[dict]) -> tuple[list[dict], list[dict]]:
    """Проба пополам: `cal` (подбор порога) и `test` (честная проверка).

    По каждой метке фразы по порядку id — через одну: обе половины
    одинаково покрывают команды и «не команды». Не зависит от уровня:
    restrict меняет метки, но делит исходный порядок.
    """
    by: dict[str, list[int]] = {}
    for i, e in enumerate(evals):
        by.setdefault(e.get("split_key", e["label"]), []).append(i)
    cal: set[int] = set()
    for idx in by.values():
        idx.sort(key=lambda i: evals[i]["id"])
        cal.update(idx[0::2])
    return [e for i, e in enumerate(evals) if i in cal], [e for i, e in enumerate(evals) if i not in cal]


def all_eval_texts() -> list[str]:
    return [o["text"] for name in config.EVAL_SETS for o in load_eval(name)]


# --- описания меток


def load_descriptions(path: Path = config.LABELS_YAML) -> dict[str, str]:
    import yaml

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    labels = data.get("labels") or {}
    bad = [k for k, v in labels.items() if not isinstance(v, str) or not v.strip()]
    if bad:
        raise SystemExit(f"{path.name}: пустое описание у {', '.join(sorted(bad))}")
    return {str(k): v.strip() for k, v in labels.items()}


def check_descriptions(labels: Iterable[str], descriptions: dict[str, str]) -> None:
    """Падает, если у метки корпуса нет описания для «Похоже, вы хотите …?»."""
    missing = sorted({lab for lab in labels if lab != "none"} - set(descriptions))
    if missing:
        raise SystemExit(
            "Нет описания в tools/intent_model/labels.yaml для меток: "
            + ", ".join(missing)
            + ". Допишите строку «"
            + missing[0]
            + ": <что сделать — с маленькой буквы>»."
        )


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    return list(parse_lines(path.read_text(encoding="utf-8").splitlines()))
