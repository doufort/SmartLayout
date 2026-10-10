#!/bin/bash
# PreToolUse hook for Edit/Write/MultiEdit: block edits to generated / released artifacts.
set -uo pipefail

file=$(cat | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)

case "$file" in
  */dist/*|*/build/*|*/.build/*|*.app/*|*.dmg)
    echo "Не редактируйте $file: это выпущенная сборка или распакованный артефакт. Меняйте исходники (app/, Sources/) и пересобирайте." >&2
    exit 2
    ;;
esac
exit 0
