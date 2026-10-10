#!/usr/bin/env python3
"""Validate SmartLayout dictionaries (slang_*.txt, typos_*.txt, style_profile.json).

Usage:
    python3 tools/check_dicts.py [RESOURCES_DIR | FILE ...]

Exit code 0 = all good, 1 = errors found. Used by tests and by the
Claude Code PostToolUse hook, so keep the output short and actionable.
"""
from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "Resources"

CYRILLIC = re.compile(r"[а-яё]", re.IGNORECASE)
LATIN = re.compile(r"[a-z]", re.IGNORECASE)
# A typo key is a single "word" the engine sees between delimiters.
KEY_RE = re.compile(r"^[^\s=#]+$")


def read_lines(path: Path) -> list[str]:
    raw = path.read_bytes()
    return raw.decode("utf-8").split("\n")


def entries(path: Path) -> list[tuple[int, str]]:
    """(1-based line number, text) for non-empty, non-comment lines."""
    out = []
    for i, line in enumerate(read_lines(path), 1):
        if line.strip() and not line.startswith("#"):
            out.append((i, line))
    return out


def lang_of(path: Path) -> str:
    return path.stem.rsplit("_", 1)[-1]


def check_encoding(path: Path) -> list[str]:
    errs = []
    raw = path.read_bytes()
    name = path.name
    if raw.startswith(b"\xef\xbb\xbf"):
        errs.append(f"{name}: UTF-8 BOM в начале файла")
    if b"\r" in raw:
        errs.append(f"{name}: CRLF переводы строк (нужны LF)")
    if raw and not raw.endswith(b"\n"):
        errs.append(f"{name}: нет перевода строки в конце файла")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        return errs + [f"{name}: не UTF-8 ({e})"]
    if unicodedata.normalize("NFC", text) != text:
        errs.append(f"{name}: текст не в NFC (й/ё могут быть разложены на два символа)")
    return errs


def check_slang(path: Path) -> list[str]:
    errs = check_encoding(path)
    lang = lang_of(path)
    words = entries(path)
    counts = Counter(w for _, w in words)
    for n, w in words:
        where = f"{path.name}:{n}"
        if w != w.strip() or " " in w or "\t" in w:
            errs.append(f"{where}: пробелы в слове {w!r} (одно слово на строку)")
        if w != w.lower():
            errs.append(f"{where}: {w!r} не в нижнем регистре")
        if lang == "ru" and LATIN.search(w):
            errs.append(f"{where}: латиница в русском слове {w!r} (смешанная раскладка?)")
        if lang == "en" and CYRILLIC.search(w):
            errs.append(f"{where}: кириллица в английском слове {w!r}")
        if counts[w] > 1:
            errs.append(f"{where}: дубликат {w!r}")
            counts[w] = 1  # report once
    return errs


def parse_typos(path: Path) -> tuple[list[tuple[int, str, str]], list[str]]:
    pairs, errs = [], []
    for n, line in entries(path):
        where = f"{path.name}:{n}"
        if line.count("=") != 1:
            errs.append(f"{where}: ожидается формат ошибка=исправление, получено {line!r}")
            continue
        wrong, right = line.split("=")
        if not wrong or not right:
            errs.append(f"{where}: пустая часть в {line!r}")
            continue
        if wrong != wrong.strip() or right != right.strip():
            errs.append(f"{where}: пробелы по краям в {line!r}")
        pairs.append((n, wrong, right))
    return pairs, errs


def check_typos(path: Path, slang: set[str] | None = None) -> list[str]:
    errs = check_encoding(path)
    lang = lang_of(path)
    pairs, perrs = parse_typos(path)
    errs += perrs
    keys = Counter(w for _, w, _ in pairs)
    targets = {r for _, _, r in pairs}
    for n, wrong, right in pairs:
        where = f"{path.name}:{n}"
        if not KEY_RE.match(wrong):
            errs.append(f"{where}: ключ {wrong!r} должен быть одним словом")
        if wrong != wrong.lower():
            errs.append(f"{where}: ключ {wrong!r} не в нижнем регистре")
        if wrong == right:
            errs.append(f"{where}: исправление совпадает с ошибкой ({wrong!r})")
        if keys[wrong] > 1:
            errs.append(f"{where}: ключ {wrong!r} встречается несколько раз")
            keys[wrong] = 1
        if wrong in targets:
            errs.append(f"{where}: {wrong!r} одновременно ошибка и чьё-то исправление (цепочка/цикл)")
        if lang == "ru" and LATIN.search(wrong + right):
            errs.append(f"{where}: латиница в русской паре {wrong}={right}")
        if lang == "en" and CYRILLIC.search(wrong + right):
            errs.append(f"{where}: кириллица в английской паре {wrong}={right}")
        if slang and wrong in slang:
            errs.append(
                f"{where}: {wrong!r} есть и в slang_{lang}.txt — "
                "сленг не исправляется, а опечатка исправляется; оставьте в одном файле"
            )
    return errs


def check_style_profile(path: Path) -> list[str]:
    errs = check_encoding(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        return errs + [f"{path.name}: невалидный JSON ({e})"]
    if not isinstance(data, dict):
        return errs + [f"{path.name}: корень должен быть объектом"]
    if not isinstance(data.get("description"), str) or not data["description"].strip():
        errs.append(f"{path.name}: нужно непустое строковое поле description")
    for key in ("samples", "words"):
        val = data.get(key)
        if not isinstance(val, list) or not all(isinstance(s, str) and s.strip() for s in val):
            errs.append(f"{path.name}: {key} должен быть списком непустых строк")
            continue
        dups = [s for s, c in Counter(val).items() if c > 1]
        if dups:
            errs.append(f"{path.name}: дубликаты в {key}: {dups}")
    extra = set(data) - {"description", "samples", "words"}
    if extra:
        errs.append(f"{path.name}: неизвестные поля {sorted(extra)}")
    return errs


def check_dir(d: Path) -> list[str]:
    errs: list[str] = []
    for lang in ("ru", "en"):
        slang_path = d / f"slang_{lang}.txt"
        typos_path = d / f"typos_{lang}.txt"
        slang: set[str] = set()
        if slang_path.exists():
            errs += check_slang(slang_path)
            slang = {w for _, w in entries(slang_path)}
        else:
            errs.append(f"нет файла {slang_path.name}")
        if typos_path.exists():
            errs += check_typos(typos_path, slang)
        else:
            errs.append(f"нет файла {typos_path.name}")
    sp = d / "style_profile.json"
    if sp.exists():
        errs += check_style_profile(sp)
    return errs


def check_path(p: Path) -> list[str]:
    if p.is_dir():
        return check_dir(p)
    if p.name.startswith("slang_") or p.name.startswith("typos_"):
        # Cross-file checks need the sibling files, so validate the whole dir.
        return check_dir(p.parent)
    if p.name == "style_profile.json":
        return check_style_profile(p)
    return []


def main(argv: list[str]) -> int:
    paths = [Path(a) for a in argv] or [DEFAULT_DIR]
    errs: list[str] = []
    seen: set[str] = set()
    for p in paths:
        for e in check_path(p.resolve()):
            if e not in seen:
                seen.add(e)
                errs.append(e)
    for e in errs:
        print(e, file=sys.stderr)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
