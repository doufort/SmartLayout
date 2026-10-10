"""Checks on the Swift sources and build script that need no Mac and no build."""
import json
import re

import pytest

import swift_source
from conftest import ROOT

SOURCES = swift_source.SOURCES


@pytest.fixture(scope="module")
def plists():
    return swift_source.build_script_plists()


def read(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


# ---- build_app.sh ------------------------------------------------------------

def test_info_plist_essentials(plists):
    info = plists["Info.plist"]
    assert info["CFBundleIdentifier"] == "com.dmitry.smartlayout"
    assert info["CFBundleExecutable"] == "SmartLayout"
    assert info["CFBundlePackageType"] == "APPL"
    assert info["LSUIElement"] is True
    assert re.fullmatch(r"\d+\.\d+(\.\d+)?", info["CFBundleShortVersionString"])
    assert info["CFBundleVersion"].isdigit()


def test_min_os_matches_package_swift(plists):
    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    m = re.search(r"\.macOS\(\.v(\d+)\)", package)
    assert m and plists["Info.plist"]["LSMinimumSystemVersion"] == f"{m.group(1)}.0"


def test_launch_agent_matches_login_item(plists):
    m = re.search(r'static let agentPlist = "([^"]+)"', read("LoginItem.swift"))
    assert m, "LoginItem.agentPlist не найден"
    agent = plists[m.group(1)]
    assert f"{agent['Label']}.plist" == m.group(1), "SMAppService.agent(plistName:) ищет файл по имени"
    assert agent["AssociatedBundleIdentifiers"] == [plists["Info.plist"]["CFBundleIdentifier"]]
    assert agent["BundleProgram"] == "Contents/MacOS/" + plists["Info.plist"]["CFBundleExecutable"]
    assert agent["RunAtLoad"] is True
    # Перезапуск после сбоя, но «Выход» из меню (код 0) действительно выходит.
    assert agent["KeepAlive"] == {"SuccessfulExit": False}


def test_build_script_ships_icon(plists):
    assert plists["Info.plist"].get("CFBundleIconFile") == "AppIcon"
    assert (ROOT / "Resources" / "AppIcon.icns").exists()


def test_build_script_copies_every_resource_the_code_loads():
    names = set()
    for f in SOURCES.glob("*.swift"):
        names |= set(re.findall(r'forResource: "([^"]+)", withExtension: "(\w+)"', f.read_text(encoding="utf-8")))
    names |= {(n, "txt") for n in ("slang_ru", "slang_en", "typos_ru", "typos_en")}  # грузятся в цикле
    for name, ext in names:
        assert (ROOT / "Resources" / f"{name}.{ext}").exists(), f"{name}.{ext}"
    script = (ROOT / "build_app.sh").read_text(encoding="utf-8")
    assert "cp Resources/*.txt Resources/*.json Resources/AppIcon.icns" in script


def test_build_script_hardened_runtime_and_universal():
    script = (ROOT / "build_app.sh").read_text(encoding="utf-8")
    assert script.count("--options runtime") >= 2, "hardened runtime и для ad-hoc, и для Developer ID"
    assert "--arch arm64 --arch x86_64" in script
    assert 'UNIVERSAL="${UNIVERSAL:-auto}"' in script


# ---- AI ---------------------------------------------------------------------

def test_ai_presets_use_https_except_localhost():
    urls = re.findall(r'url: "([^"]*)"', read("AIClient.swift"))
    assert urls
    for u in filter(None, urls):
        assert u.startswith("https://") or u.startswith(("http://localhost", "http://127.0.0.1")), u


def test_banned_phrases_are_lowercase():
    """violations() сравнивает с text.lowercased(), поэтому фраза с заглавной буквой никогда не сработает."""
    for p in swift_source.banned_phrases():
        assert p == p.lower(), p


def test_author_samples_pass_human_style():
    """Собственные тексты автора не должны нарушать HumanStyle, иначе вариант,
    сохранивший его формулировки, будет отклонён как «похож на сгенерированный»."""
    profile = json.loads((ROOT / "Resources" / "style_profile.json").read_text(encoding="utf-8"))
    banned = swift_source.banned_phrases()
    for sample in profile["samples"]:
        low = sample.lower()
        assert not [p for p in banned if p in low], sample
        assert not re.search(r"\bот\s+\S+\s+до\s+\S+", low), sample


def test_review_prompt_example_is_valid_json():
    """Пример ответа в reviewPrompt должен быть корректным JSON: модель копирует его формат."""
    src = read("AIClient.swift")
    m = re.search(r'Ответ: (\{"fixed".*?"\})\n', src, re.S)
    assert m
    example = re.sub(r"\\\n\s*", "", m.group(1))
    obj = json.loads(example)
    assert set(obj) == {"fixed", "alternative", "note", "next"}


# ---- Regression guards for fixes from docs/AUDIT.md ---------------------------

def test_tests_do_not_touch_real_user_data():
    """Swift-тесты не должны создавать LearningStore/WordStore по умолчанию:
    раньше `swift test` стирал ~/Library/Application Support/SmartLayout/learning.json."""
    for f in (ROOT / "Tests").rglob("*.swift"):
        src = f.read_text(encoding="utf-8")
        assert "LearningStore()" not in src, f.name
        assert "WordStore()" not in src, f.name


def test_undo_not_armed_after_enter_or_tab():
    src = read("KeyboardMonitor.swift")
    body = src[src.index("private func boundary"):src.index("private func applyEarly")]
    assert "if case .char = delimiter" in body, "отмена по Backspace после Enter/Tab стирает чужой текст"


def test_clipboard_restores_all_types():
    src = read("TextAccess.swift")
    assert "pasteboardItems" in src, "буфер обмена должен сохраняться целиком, а не только .string"


def test_default_app_exclusions_cover_terminals_and_password_managers():
    src = read("AppExclusions.swift")
    for bundle_id in ("com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.jetbrains.",
                      "com.1password.", "com.bitwarden.desktop"):
        assert f'"{bundle_id}"' in src, bundle_id
    locked = src[src.index("static let locked"):src.index("static let defaults")]
    assert "com.1password." in locked and "com.bitwarden.desktop" in locked, "менеджеры паролей нельзя включить обратно"


def test_monitor_skips_excluded_apps_and_secure_input():
    src = read("KeyboardMonitor.swift")
    handle = src[src.index("private func handle"):src.index("private func lateCharFix")]
    assert "AppExclusions.frontmostExcluded" in handle and "IsSecureEventInputEnabled()" in handle
    assert "wordIsSecret" in handle


def test_ai_never_reads_secure_fields():
    src = read("TextAccess.swift")
    read_fn = src[src.index("static func read()"):src.index("static func select(")]
    assert "isSecure(el)" in read_fn
    ai = read("AIController.swift")
    assert ai.count("focusedIsSecure()") >= 2, "автопроверка и горячие клавиши"


def test_privacy_defaults_for_new_installs():
    src = read("Settings.swift")
    for key in ("aiAutoCheck", "aiReadWindow"):
        assert f'd.object(forKey: "{key}") as? Bool ?? false' in src, key
        assert f'"{key}": true' not in src, key
