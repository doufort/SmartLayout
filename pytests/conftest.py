import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

RESOURCES = ROOT / "Resources"


def _app_source() -> Path | None:
    """The build under test: $SMARTLAYOUT_APP (.app or .dmg) or the newest dist/*.dmg."""
    env = os.environ.get("SMARTLAYOUT_APP")
    if env:
        return Path(env)
    dmgs = sorted((ROOT / "dist").glob("*.dmg"))
    return dmgs[-1] if dmgs else None


@pytest.fixture(scope="session")
def resources() -> Path:
    return RESOURCES


@pytest.fixture(scope="session")
def app_bundle() -> Path:
    import bundle

    src = _app_source()
    if src is None:
        pytest.skip("нет сборки: положите .dmg в dist/ или задайте SMARTLAYOUT_APP")
    try:
        return bundle.resolve_app(src)
    except RuntimeError as e:
        pytest.skip(str(e))


@pytest.fixture(scope="session")
def binary_strings(app_bundle) -> list[str]:
    import bundle

    exe = app_bundle / "Contents" / "MacOS" / "SmartLayout"
    return bundle.utf8_strings(exe.read_bytes())
