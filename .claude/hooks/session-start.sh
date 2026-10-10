#!/bin/bash
# Prepare a Claude Code cloud session: pytest for the test suite, 7z for unpacking .dmg builds.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

if ! python3 -c "import pytest" 2>/dev/null; then
  pip3 install --quiet --disable-pip-version-check -r requirements-dev.txt
fi

if ! command -v 7z >/dev/null 2>&1; then
  (apt-get update -qq && apt-get install -y -qq p7zip-full) >/dev/null 2>&1 \
    || echo "session-start: 7z не установлен, тесты сборки (pytests/test_bundle.py) будут пропущены" >&2
fi

echo 'export PYTHONDONTWRITEBYTECODE=1' >> "${CLAUDE_ENV_FILE:-/dev/null}"
