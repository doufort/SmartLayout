"""LayoutMap: EN QWERTY <-> Russian ЙЦУКЕН (tables read from LayoutMap.swift)."""
import pytest

from layout_map import (
    EN_KEYS_THAT_ARE_RU_LETTERS,
    EN_LOWER,
    EN_TO_RU,
    EN_UPPER,
    RU_LOWER,
    RU_TO_EN,
    RU_UPPER,
    TABLES,
    convert,
)

RU_LETTERS = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"


def test_tables_have_equal_length():
    assert {len(t) for t in TABLES} == {34}


def test_tables_have_no_duplicates():
    for t in TABLES:
        assert len(set(t)) == len(t), t


def test_all_33_russian_letters_present():
    assert set(RU_LETTERS) <= set(RU_LOWER)
    assert set(RU_LETTERS.upper()) <= set(RU_UPPER)


def test_case_is_preserved_for_letters():
    for en, ru in zip(EN_LOWER + EN_UPPER, RU_LOWER + RU_UPPER):
        if en.isalpha() and ru.isalpha():
            assert en.isupper() == ru.isupper(), (en, ru)


def test_every_russian_letter_roundtrips():
    for ch in RU_LETTERS + RU_LETTERS.upper():
        assert convert(convert(ch, "ru"), "en") == ch, ch


def test_every_letter_key_roundtrips():
    keys = [k for k in EN_LOWER + EN_UPPER if EN_TO_RU[k].isalpha()]
    assert len(keys) == 66
    for k in keys:
        assert convert(convert(k, "en"), "ru") == k, k


def test_ru_punctuation_is_kept():
    """"." and "," are punctuation on both layouts: RU text keeps them, while
    EN "/" and "?" (the same physical keys) still become "." and ","."""
    assert convert(".", "ru") == "."
    assert convert(",", "ru") == ","
    assert convert("/", "en") == "."
    assert convert("?", "en") == ","
    assert "." not in RU_TO_EN and "," not in RU_TO_EN


def test_en_keys_that_are_ru_letters_matches_tables():
    """LayoutMap.enKeysThatAreRuLetters must list exactly the EN symbols that are RU letters."""
    expected = {k for k in EN_LOWER + EN_UPPER if not k.isalpha() and EN_TO_RU[k].isalpha()}
    assert EN_KEYS_THAT_ARE_RU_LETTERS == expected


@pytest.mark.parametrize(
    "typed, source, expected",
    [
        # Same cases as Tests/SmartLayoutTests/CoreTests.swift
        ("ghbdtn", "en", "привет"),
        ("Ghbdtn", "en", "Привет"),
        ("k.,k.", "en", "люблю"),
        ("fdnjvfnbxtcrb", "en", "автоматически"),
        ("`krf", "en", "ёлка"),
        ("руддщ", "ru", "hello"),
        ("Цщкв", "ru", "Word"),
        ("вщтэе", "ru", "don't"),
        # More
        ("GHBDTN", "en", "ПРИВЕТ"),
        ("j,]tv", "en", "объем"),
        ("ndj`", "en", "твоё"),
        ("rjvgm.nth", "en", "компьютер"),
        ("ctujlyz z jgznm d jabct?", "en", "сегодня я опять в офисе,"),
        ("ghbdtn123", "en", "привет123"),
        ("руддщ, цщкдв.", "ru", "hello, world."),
        ("", "en", ""),
    ],
)
def test_convert(typed, source, expected):
    assert convert(typed, source) == expected


def test_pangram_roundtrip():
    ru = "съешь же ещё этих мягких французских булок да выпей чаю"
    assert convert(convert(ru, "ru"), "en") == ru


def test_non_layout_characters_pass_through():
    s = "123 !@#$%^&*()-=_+ \t\n😀 €"
    assert convert(s, "en") == convert(s, "ru") == s
