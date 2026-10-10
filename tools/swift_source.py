"""Read constants straight out of the Swift sources, so Python tests and
the shipped binary are checked against the same source of truth."""
from __future__ import annotations

import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "SmartLayout"


def _swift_string(literal: str) -> str:
    """Unescape a simple Swift string literal body (\\" and \\\\ only)."""
    return re.sub(r"\\(.)", r"\1", literal)


def layout_tables() -> dict[str, str]:
    """enLower/ruLower/enUpper/ruUpper from LayoutMap.swift."""
    src = (SOURCES / "LayoutMap.swift").read_text(encoding="utf-8")
    out = {}
    for name in ("enLower", "ruLower", "enUpper", "ruUpper"):
        m = re.search(rf'static let {name} = Array\("((?:[^"\\]|\\.)*)"\)', src)
        if not m:
            raise ValueError(f"{name} не найден в LayoutMap.swift")
        out[name] = _swift_string(m.group(1))
    return out


def banned_phrases() -> list[str]:
    """HumanStyle.bannedPhrases from HumanStyle.swift."""
    src = (SOURCES / "HumanStyle.swift").read_text(encoding="utf-8")
    m = re.search(r"static let bannedPhrases = \[(.*?)\]", src, re.S)
    if not m:
        raise ValueError("bannedPhrases не найден в HumanStyle.swift")
    return [_swift_string(s) for s in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))]


def build_script_plists() -> dict[str, dict]:
    """Info.plist and LaunchAgent plist as build_app.sh writes them.

    Shell variables in the heredocs are substituted with their defaults
    (`VERSION="${VERSION:-1.0}"` → 1.0).
    """
    script = (ROOT / "build_app.sh").read_text(encoding="utf-8")
    defaults = dict(re.findall(r'^(\w+)="\$\{\1:-([^}]*)\}"', script, re.M))
    out = {}
    for target, body in re.findall(r'cat > "([^"]+)" <<PLIST\n(.*?)\nPLIST', script, re.S):
        body = re.sub(r"\$\{(\w+)\}", lambda m: defaults.get(m.group(1), m.group(0)), body)
        out[target.rsplit("/", 1)[-1]] = plistlib.loads(body.encode())
    return out
