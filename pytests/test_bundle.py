"""Checks against a built SmartLayout.app (from dist/*.dmg or $SMARTLAYOUT_APP).

Tests marked xfail(strict=True) document known defects of 1.0 (see
docs/AUDIT.md). When a defect is fixed the test starts passing, strict xfail
turns that into a failure, and the marker should simply be removed.
"""
import json
import plistlib
import re

import pytest

import bundle
import check_dicts
import swift_source
from layout_map import TABLES

ESSENTIAL_KEYS = [
    "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
    "LSMinimumSystemVersion", "LSUIElement", "CFBundleShortVersionString",
]


@pytest.fixture(scope="session")
def contents(app_bundle):
    return app_bundle / "Contents"


@pytest.fixture(scope="session")
def info(contents):
    return plistlib.loads((contents / "Info.plist").read_bytes())


@pytest.fixture(scope="session")
def macho(contents, info):
    return bundle.parse_macho(contents / "MacOS" / info["CFBundleExecutable"])


# ---- Info.plist / LaunchAgent ---------------------------------------------

def test_info_plist_essentials(info, contents):
    assert info["CFBundleIdentifier"] == "com.dmitry.smartlayout"
    assert info["CFBundlePackageType"] == "APPL"
    assert info["LSUIElement"] is True, "меню-бар приложение не должно показываться в Dock"
    assert re.fullmatch(r"\d+\.\d+(\.\d+)?", info["CFBundleShortVersionString"])
    assert info["CFBundleVersion"].isdigit()
    assert (contents / "MacOS" / info["CFBundleExecutable"]).is_file()
    if "CFBundleIconFile" in info:
        assert (contents / "Resources" / f"{info['CFBundleIconFile']}.icns").is_file()


def test_info_plist_matches_build_script(info):
    script = swift_source.build_script_plists()["Info.plist"]
    for key in ESSENTIAL_KEYS:
        assert info.get(key) == script.get(key), f"{key}: сборка {info.get(key)!r}, build_app.sh {script.get(key)!r}"


def test_launch_agent_matches_build_script(contents):
    script = swift_source.build_script_plists()["com.dmitry.smartlayout.agent.plist"]
    built = plistlib.loads((contents / "Library" / "LaunchAgents" / "com.dmitry.smartlayout.agent.plist").read_bytes())
    assert built == script


def test_launch_agent(contents, info):
    plists = list((contents / "Library" / "LaunchAgents").glob("*.plist"))
    assert len(plists) == 1
    agent = plistlib.loads(plists[0].read_bytes())
    assert plists[0].stem == agent["Label"], "SMAppService.agent(plistName:) ищет файл по имени"
    assert info["CFBundleIdentifier"] in agent["AssociatedBundleIdentifiers"]
    assert (contents.parent / agent["BundleProgram"]).is_file()
    assert agent["RunAtLoad"] is True
    # Restart after a crash, but let "Quit" (exit 0) actually quit.
    assert agent["KeepAlive"] == {"SuccessfulExit": False}


def test_binary_min_os_matches_plist(info, macho):
    for s in macho.slices:
        assert s.min_os == info["LSMinimumSystemVersion"]


def test_binary_is_signed_with_bundle_id(macho, info):
    for s in macho.slices:
        assert s.signed
        assert s.identifier == info["CFBundleIdentifier"]


# ---- Resources ---------------------------------------------------------------

def test_bundled_dictionaries_are_valid(contents):
    errs = check_dicts.check_dir(contents / "Resources")
    # 1.0 shipped style_profile.json without a trailing newline: cosmetic.
    errs = [e for e in errs if "перевода строки" not in e]
    assert errs == []


@pytest.mark.parametrize("name", ["slang_ru.txt", "slang_en.txt", "typos_ru.txt", "typos_en.txt"])
def test_repo_dictionaries_match_build(contents, resources, name):
    built = [w for _, w in check_dicts.entries(contents / "Resources" / name)]
    repo = [w for _, w in check_dicts.entries(resources / name)]
    assert repo == built, f"{name}: в репозитории и в сборке разные словари — пересоберите приложение"


def test_repo_style_profile_matches_build(contents, resources):
    load = lambda p: json.loads(p.read_text(encoding="utf-8"))
    assert load(resources / "style_profile.json") == load(contents / "Resources" / "style_profile.json")


def test_no_stray_files_in_resources(contents):
    allowed = {"AppIcon.icns", "style_profile.json"} | {
        f"{k}_{l}.txt" for k in ("slang", "typos") for l in ("ru", "en")
    }
    assert {p.name for p in (contents / "Resources").iterdir()} <= allowed


# ---- Strings compiled into the binary ---------------------------------------

def test_layout_tables_match_sources(binary_strings):
    for table in TABLES:
        assert table in binary_strings, f"таблица {table!r} из LayoutMap.swift не найдена: сборка устарела?"


def test_ai_endpoints(binary_strings):
    urls = {s for s in binary_strings if s.startswith(("http://", "https://"))}
    assert urls, "не найдены адреса AI-провайдеров"
    for u in urls:
        if u.startswith("http://"):
            assert u.startswith(("http://localhost", "http://127.0.0.1")), f"незашифрованный адрес {u}"


def test_ai_key_stored_in_keychain(binary_strings):
    assert "apiKey" in binary_strings
    # The key goes to SecItem*, not to UserDefaults (where any process can read it).
    assert any("Keychain.swift" in s for s in binary_strings)


@pytest.mark.parametrize("phrase", [p for p in swift_source.banned_phrases() if len(p.encode()) > 15])
def test_banned_phrases_match_sources(binary_strings, phrase):
    # Swift хранит строки до 15 байт прямо в коде, их в бинарнике не найти.
    assert any(phrase in s for s in binary_strings), f"{phrase!r} нет в сборке: сборка устарела?"


# ---- Known defects in 1.0 (docs/AUDIT.md) -------------------------------------

@pytest.mark.xfail(strict=True, reason="AUDIT #1: сборка только arm64, на Intel Mac не запустится")
def test_universal_binary(macho):
    assert set(macho.archs) >= {"arm64", "x86_64"}


@pytest.mark.xfail(strict=True, reason="AUDIT #2: ad-hoc подпись без Developer ID и hardened runtime")
def test_developer_id_signature(macho):
    for s in macho.slices:
        assert not s.adhoc and s.team_id and s.hardened_runtime


@pytest.mark.xfail(strict=True, reason="AUDIT #3: нет проверки полей пароля/Secure Input")
def test_secure_input_guard(binary_strings):
    blob = "\n".join(binary_strings)
    found = "AXSecureTextField" in blob or "IsSecureEventInputEnabled" in blob
    assert found, "в бинарнике нет ни AXSecureTextField, ни IsSecureEventInputEnabled"


@pytest.mark.xfail(strict=True, reason="AUDIT #4: нет списка приложений-исключений (терминалы, IDE)")
def test_app_exclusion_list(binary_strings):
    blob = "\n".join(binary_strings)
    found = "com.apple.Terminal" in blob or "com.googlecode.iterm2" in blob
    assert found, "в бинарнике нет bundle id терминалов для исключения"
