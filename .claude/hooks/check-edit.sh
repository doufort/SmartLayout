#!/bin/bash
# PostToolUse hook for Edit/Write/MultiEdit: validates what was just changed and
# feeds problems back to Claude (exit 2 = stderr is shown to the model).
set -uo pipefail

input=$(cat)
file=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)
[ -z "$file" ] && exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$root" || exit 0

case "$file" in
  */Resources/*.txt|*/Resources/style_profile.json)
    if ! out=$(python3 tools/check_dicts.py "$file" 2>&1); then
      printf 'Словарь не прошёл проверку (tools/check_dicts.py):\n%s\n' "$out" >&2
      exit 2
    fi
    ;;
  */build_app.sh)
    if ! out=$(bash -n "$file" 2>&1 && python3 -c 'import sys; sys.path.insert(0,"tools"); import swift_source; swift_source.build_script_plists()' 2>&1); then
      printf 'build_app.sh: синтаксис или plist внутри скрипта сломан:\n%s\n' "$out" >&2
      exit 2
    fi
    ;;
  *.py)
    if ! out=$(python3 -m py_compile "$file" 2>&1); then
      printf 'Синтаксическая ошибка Python:\n%s\n' "$out" >&2
      exit 2
    fi
    ;;
  *.swift)
    # На Mac — синтаксическая проверка файла; полные `swift build && swift test` гоняет CI.
    if command -v swiftc >/dev/null 2>&1; then
      if ! out=$(swiftc -parse "$file" 2>&1); then
        printf 'swiftc -parse:\n%s\n' "$out" >&2
        exit 2
      fi
    fi
    ;;
  *) exit 0 ;;
esac

# Fast regression run for anything that touches app data or tooling.
case "$file" in
  */Resources/*|*/Sources/*|*/Tests/*|*/tools/*|*/pytests/*|*/build_app.sh)
    if ! out=$(python3 -m pytest -q -x --no-header -p no:cacheprovider 2>&1); then
      printf 'Тесты упали после правки %s:\n%s\n' "$file" "$(printf '%s' "$out" | tail -25)" >&2
      exit 2
    fi
    ;;
esac
exit 0
