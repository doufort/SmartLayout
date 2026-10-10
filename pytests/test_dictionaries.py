"""Dictionaries shipped in SmartLayout.app/Contents/Resources."""
import json

import pytest

import check_dicts
from layout_map import convert


def words(path):
    return [w for _, w in check_dicts.entries(path)]


def typos(path):
    pairs, errs = check_dicts.parse_typos(path)
    assert not errs, errs
    return {w: r for _, w, r in pairs}


def test_validator_passes_on_repo_resources(resources):
    assert check_dicts.check_dir(resources) == []


@pytest.mark.parametrize("lang", ["ru", "en"])
def test_dictionaries_not_empty(resources, lang):
    assert len(words(resources / f"slang_{lang}.txt")) > 20
    assert len(typos(resources / f"typos_{lang}.txt")) > 20


@pytest.mark.parametrize("lang", ["ru", "en"])
def test_typo_fix_is_not_itself_a_typo(resources, lang):
    """Applying the typo table twice must give the same result (no chains)."""
    table = typos(resources / f"typos_{lang}.txt")
    for wrong, right in table.items():
        for token in right.replace("-", " ").split():
            assert token.lower() not in table, f"{wrong}={right}: {token!r} снова будет исправлено"


@pytest.mark.parametrize("lang", ["ru", "en"])
def test_slang_never_listed_as_typo(resources, lang):
    slang = set(words(resources / f"slang_{lang}.txt"))
    table = typos(resources / f"typos_{lang}.txt")
    assert not slang & set(table), "слово и в сленге, и в опечатках"


def test_slang_does_not_collide_across_layouts(resources):
    """A slang word typed in the wrong layout must not be another slang word.

    Otherwise autoswitch cannot tell whether "щл" was meant to be "ok".
    """
    ru = set(words(resources / "slang_ru.txt"))
    en = set(words(resources / "slang_en.txt"))
    assert not {w for w in ru if convert(w, "ru") in en}
    assert not {w for w in en if convert(w, "en") in ru}


def test_typo_keys_are_not_wrong_layout_slang(resources):
    """A typo key must not be what a slang word looks like in the other layout."""
    ru_typos = typos(resources / "typos_ru.txt")
    en_typos = typos(resources / "typos_en.txt")
    en_slang = set(words(resources / "slang_en.txt"))
    ru_slang = set(words(resources / "slang_ru.txt"))
    assert not {k for k in ru_typos if convert(k, "ru") in en_slang}
    assert not {k for k in en_typos if convert(k, "en") in ru_slang}


def test_style_profile_words_are_known_slang(resources):
    """Words the author uses on purpose must be protected from autocorrect."""
    profile = json.loads((resources / "style_profile.json").read_text(encoding="utf-8"))
    slang = set(words(resources / "slang_ru.txt"))
    ru_typos = typos(resources / "typos_ru.txt")
    for w in profile["words"]:
        assert w not in ru_typos, f"{w!r} из профиля стиля будет «исправлено»"
    # Words the profile description itself calls out as intentional slang.
    for w in ("прога", "тупо", "прям", "считай", "норм", "чет"):
        assert w in slang, f"{w!r} описан в style_profile как сленг, но его нет в slang_ru.txt"


# ---- validator self-tests: make sure it actually catches problems ----------

@pytest.fixture
def bad_dir(tmp_path, resources):
    for f in resources.iterdir():
        (tmp_path / f.name).write_bytes(f.read_bytes())
    return tmp_path


@pytest.mark.parametrize(
    "fname, content, needle",
    [
        ("typos_ru.txt", "# x\nтест=тест\n", "совпадает"),
        ("typos_ru.txt", "# x\nа=б\nа=в\n", "несколько раз"),
        ("typos_ru.txt", "# x\nа=б\nб=в\n", "цепочка"),
        ("typos_ru.txt", "# x\nбез разделителя\n", "формат"),
        ("typos_ru.txt", "# x\nnorm=норм\n", "латиница"),
        ("typos_ru.txt", "# x\nпрога=программа\n", "есть и в slang_ru"),
        ("typos_en.txt", "# x\nTeh=the\n", "нижнем регистре"),
        ("slang_ru.txt", "# x\nкек\nкек\n", "дубликат"),
        ("slang_ru.txt", "# x\nКек\n", "нижнем регистре"),
        ("slang_ru.txt", "# x\nкeк\n", "латиница"),  # latin "e" inside
        ("slang_en.txt", "# x\nlol\r\n", "CRLF"),
        ("slang_en.txt", "﻿# x\nlol\n", "BOM"),
        ("slang_en.txt", "# x\nlol", "перевода строки"),
        ("style_profile.json", '{"description": "", "samples": [], "words": []}\n', "description"),
        ("style_profile.json", "{oops", "JSON"),
    ],
)
def test_validator_catches(bad_dir, fname, content, needle):
    (bad_dir / fname).write_text(content, encoding="utf-8", newline="")
    errs = check_dicts.check_dir(bad_dir)
    assert any(needle in e for e in errs), errs
