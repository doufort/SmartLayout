"""Python model of LayoutMap.swift (EN QWERTY <-> Russian ЙЦУКЕН).

The tables are read from Sources/SmartLayout/LayoutMap.swift, and the
conversion rules mirror the Swift code:

* enToRu maps every key of the four tables;
* ruToEn skips the Russian "." and "," (they are punctuation in both
  layouts, so text typed in RU keeps them as is).

Note: the tables describe the *Russian – PC* layout (ё on the `~ key,
"." on the "/" key). Apple's default *Russian* layout puts "." "," and
other punctuation elsewhere. See docs/AUDIT.md.
"""
from __future__ import annotations

from swift_source import layout_tables

_t = layout_tables()
EN_LOWER, RU_LOWER, EN_UPPER, RU_UPPER = _t["enLower"], _t["ruLower"], _t["enUpper"], _t["ruUpper"]
TABLES = (EN_LOWER, EN_UPPER, RU_LOWER, RU_UPPER)

EN_TO_RU = dict(zip(EN_LOWER + EN_UPPER, RU_LOWER + RU_UPPER))
RU_TO_EN = {r: e for e, r in zip(EN_LOWER, RU_LOWER) if r != "."}
RU_TO_EN |= {r: e for e, r in zip(EN_UPPER, RU_UPPER) if r != ","}

# LayoutMap.enKeysThatAreRuLetters
EN_KEYS_THAT_ARE_RU_LETTERS = set("`[];',.~{}:\"<>")


def convert(text: str, source: str) -> str:
    """LayoutMap.convert(text, from: source): retype text as if typed on the other layout."""
    table = EN_TO_RU if source == "en" else RU_TO_EN
    return "".join(table.get(ch, ch) for ch in text)
