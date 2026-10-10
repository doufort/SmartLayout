#!/usr/bin/env python3
"""Rebuild Resources/words_ru.txt and Resources/words_en.txt.

Source: FrequencyWords by Hermit Dave (OpenSubtitles 2018), CC BY-SA 4.0,
https://github.com/hermitdave/FrequencyWords. Keeps lowercase words made of
letters only (2+ letters), most frequent first, top 50 000 Russian and
30 000 English. These lists let CorrectionEngine answer "is this a word /
a word start" without calling the macOS spell checker inside the key tap.

    python3 tools/build_wordlists.py            # download and rebuild
"""
from __future__ import annotations

import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{lang}/{lang}_50k.txt"
LIMITS = {"ru": 50_000, "en": 30_000}
LETTERS = {"ru": re.compile(r"^[а-яё]{2,}$"), "en": re.compile(r"^[a-z]{2,}$")}
HEADER = ("# Частотный словарь: FrequencyWords (Hermit Dave, OpenSubtitles 2018), CC BY-SA 4.0.\n"
          "# Сборка: tools/build_wordlists.py. Лицензия: WORDLISTS_LICENSE.txt.\n")


def build(lang: str, lines: list[str]) -> list[str]:
    out, seen = [], set()
    for line in lines:
        word = line.split(" ", 1)[0].strip().lower()
        if LETTERS[lang].match(word) and word not in seen:
            seen.add(word)
            out.append(word)
            if len(out) >= LIMITS[lang]:
                break
    return out


def main() -> int:
    for lang in ("ru", "en"):
        with urllib.request.urlopen(URL.format(lang=lang), timeout=60) as r:
            lines = r.read().decode("utf-8").splitlines()
        words = build(lang, lines)
        (ROOT / "Resources" / f"words_{lang}.txt").write_text(HEADER + "\n".join(words) + "\n", encoding="utf-8")
        print(f"words_{lang}.txt: {len(words)} слов")
    return 0


if __name__ == "__main__":
    sys.exit(main())
