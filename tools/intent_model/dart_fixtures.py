"""Эталоны для Dart-токенизаторов запасного слоя (ADR-045, шаг 2).

    python -m tools.intent_model.dart_fixtures --packs <папка с распакованным
        пакетом accurate/>

Эталоны снятой «Лёгкой» (WordPiece, `tokenizer_light_mini.json`) остаются как
есть: без пакета `light/` они не пересобираются.

- `test/fixtures/intent/tokenizer_golden.json` — номера токенов HF tokenizers
  (полные словари, усечение до 64) для синтетических фраз
  `test/fixtures/intent/phrases.txt` и особых случаев ниже;
- `tokenizer_<уровень>_mini.json` — tokenizer.json пакета, в котором оставлены
  только нужные этим фразам токены и слияния: те же номера без словаря на
  мегабайты (проверяется здесь же);
- `lib/core/intent/bert_chars.g.dart` — классы знаков BertNormalizer и
  BertPreTokenizer, снятые с самой библиотеки по всем кодовым точкам.

Фразы только синтетические.
"""

from __future__ import annotations

import argparse
import copy
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test" / "fixtures" / "intent"
CHARS = ROOT / "lib" / "core" / "intent" / "bert_chars.g.dart"

# Особые случаи: перевод строки, табуляция, невидимые и управляющие знаки,
# слова длиннее 100 знаков, пустая фраза.
EXTRA = [
    "перевод\nстроки",
    "табуляция\tи\r\nвозврат каретки",
    "нулевой​пробел",
    "мягкий­перенос",
    "звонок\u0007внутри",
    "неразрывный пробел",
    "узкий пробел",
    "BOM﻿внутри",
    "замена�знака",
    "частнаязона",
    "комбинированное ё и й",
    "й разложенная",
    "x" * 101,
    "ж" * 120 + " и дальше",
    "",
    " ",
    "query: служебное слово",
]


def phrases() -> list[str]:
    lines = (FIXTURES / "phrases.txt").read_text(encoding="utf-8").split("\n")
    return [line for line in lines if line.strip()] + EXTRA


def golden(packs: Path) -> None:
    from tokenizers import Tokenizer

    texts = phrases()
    old_path = FIXTURES / "tokenizer_golden.json"
    old = json.loads(old_path.read_text(encoding="utf-8")) if old_path.exists() else {}
    result: dict = {"phrases": texts}
    for tier in ("light", "accurate"):
        path = packs / tier / "tokenizer.json"
        if not path.exists():
            if old.get("phrases") != texts or tier not in old:
                raise SystemExit(f"{tier}: нет пакета, а прежний эталон не подходит к фразам")
            result[tier] = old[tier]
            continue
        tok = Tokenizer.from_file(str(path))
        tok.enable_truncation(max_length=64)
        result[tier] = [tok.encode(t).ids for t in texts]
        full = json.loads(path.read_text(encoding="utf-8"))
        pieces = set()
        for t in texts:
            n = tok.normalizer.normalize_str(t) if tok.normalizer else t
            pieces.update(p for p, _ in tok.pre_tokenizer.pre_tokenize_str(n))
        blob = "\x00".join(pieces)
        mini = copy.deepcopy(full)
        vocab = full["model"]["vocab"]
        special = {t["content"] for t in full["added_tokens"]}
        if full["model"]["type"] == "WordPiece":
            keep = {
                t: i
                for t, i in vocab.items()
                if t in special or (t[2:] if t.startswith("##") else t) in blob
            }
        else:
            keep = {t: i for t, i in vocab.items() if t in special or t in blob}

            def joined(m) -> str:
                return "".join(m.split(" ", 1) if isinstance(m, str) else m)

            mini["model"]["merges"] = [m for m in full["model"]["merges"] if joined(m) in blob]
        mini["model"]["vocab"] = keep
        text = json.dumps(mini, ensure_ascii=False)
        small = Tokenizer.from_str(text)
        small.enable_truncation(max_length=64)
        bad = [t for t, ids in zip(texts, result[tier]) if small.encode(t).ids != ids]
        if bad:
            raise SystemExit(f"{tier}: урезанный словарь расходится: {bad[:3]}")
        (FIXTURES / f"tokenizer_{tier}_mini.json").write_text(text, encoding="utf-8")
        print(tier, "токенов в урезанном словаре:", len(keep))
    (FIXTURES / "tokenizer_golden.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=0), encoding="utf-8"
    )
    print("фраз:", len(texts))


DOCS = {
    "removed": "Знаки, которые `clean_text` убирает: Cc, Cf, Co, суррогаты, U+FFFD.",
    "space": "Знаки, которые `clean_text` заменяет пробелом.",
    "cjk": "Иероглифы: `handle_chinese_chars` окружает их пробелами.",
    "punct": "Знаки препинания `BertPreTokenizer`: каждый — отдельное слово.",
}


def chars() -> None:
    from tokenizers.normalizers import BertNormalizer
    from tokenizers.pre_tokenizers import BertPreTokenizer

    norm = BertNormalizer(clean_text=True, handle_chinese_chars=True, strip_accents=False, lowercase=False)
    pre = BertPreTokenizer()
    kinds: list[str] = []
    for cp in range(0x110000):
        if 0xD800 <= cp <= 0xDFFF:
            kinds.append("removed")
            continue
        c = chr(cp)
        n = norm.normalize_str("a" + c + "b")
        if n == "ab":
            kinds.append("removed")
        elif n == "a b":
            kinds.append("space")
        elif n == "a " + c + " b":
            kinds.append("cjk")
        elif n == "a" + c + "b":
            parts = [p for p, _ in pre.pre_tokenize_str(n)]
            kinds.append("punct" if parts == ["a", c, "b"] else "-")
        else:
            raise SystemExit(f"неожиданная нормализация U+{cp:04X}: {n!r}")
    print(Counter(kinds))
    out = [
        "// Сгенерировано tools/intent_model/dart_fixtures.py по самой библиотеке\n",
        "// tokenizers: классы всех кодовых точек для BertNormalizer (clean_text,\n",
        "// handle_chinese_chars) и BertPreTokenizer. Не править вручную.\n\n",
        "/// Классы знаков токенизатора WordPiece (ADR-045): пары «от, до»\n",
        "/// включительно, по возрастанию.\n",
        "abstract final class BertCharClasses {\n",
    ]
    for name in ("removed", "space", "cjk", "punct"):
        ranges: list[str] = []
        start = None
        for cp in range(0x110001):
            inside = cp < 0x110000 and kinds[cp] == name
            if inside and start is None:
                start = cp
            if not inside and start is not None:
                ranges += [f"0x{start:X}", f"0x{cp - 1:X}"]
                start = None
        lines, line = [], "    "
        for v in ranges:
            if len(line) + len(v) + 2 > 79:
                lines.append(line.rstrip())
                line = "    "
            line += v + ", "
        lines.append(line.rstrip())
        out.append(f"  /// {DOCS[name]}\n  static const List<int> {name} = <int>[\n")
        out.append("\n".join(lines) + "\n  ];\n\n")
    out.append(
        """  /// [code] попадает в одну из пар [ranges].
  static bool inRanges(List<int> ranges, int code) {
    var low = 0;
    var high = ranges.length ~/ 2 - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (code < ranges[mid * 2]) {
        high = mid - 1;
      } else if (code > ranges[mid * 2 + 1]) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }
}
"""
    )
    CHARS.write_text("".join(out), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--packs", type=Path, required=True)
    args = ap.parse_args()
    golden(args.packs)
    chars()


if __name__ == "__main__":
    main()
