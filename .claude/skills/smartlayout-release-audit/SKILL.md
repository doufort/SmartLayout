---
name: smartlayout-release-audit
description: Проверка новой сборки SmartLayout (.dmg/.app) перед релизом — архитектуры, подпись, Info.plist, LaunchAgent, ресурсы, соответствие исходникам и открытые пункты docs/AUDIT.md. Используй, когда пользователь даёт новый .dmg, просит «проверь сборку», «готово к релизу?» или «что исправлено в новой версии».
---

# Аудит сборки SmartLayout

Все проверки работают на Linux без Xcode: `.dmg` распаковывается через `7z`, Mach-O разбирает `tools/bundle.py`, строки бинарника сверяются с исходниками через `tools/swift_source.py`.

## Шаги

1. Положи сборку в `dist/SmartLayout-<версия>.dmg` (старые `.dmg` из `dist/` убери: тесты берут последний по имени) или задай `SMARTLAYOUT_APP=/путь/к/.app|.dmg`. Свежую локальную сборку проверяй так: `./build_app.sh && SMARTLAYOUT_APP=build/SmartLayout.app python3 -m pytest tests/test_bundle.py`.
2. Отчёт: `python3 tools/bundle.py dist/SmartLayout-<версия>.dmg` (версия, архитектуры, тип подписи, hardened runtime).
3. Тесты: `python3 -m pytest`.
4. Разбор результатов:
   - **XPASS(strict) → FAILED** у теста с причиной `AUDIT #N` значит, что пункт исправлен. Убери `xfail` и перенеси пункт в docs/AUDIT.md из «Открытые» в «Исправлено» с номером версии.
   - `test_layout_tables_match_sources`, `test_banned_phrases_match_sources` упали — сборка собрана не из текущих исходников (устарела или собрана из другой ветки).
   - `test_repo_*_match_build`, `test_info_plist_matches_build_script` упали — словари, Info.plist или LaunchAgent в репозитории и в сборке разошлись. Выясни, что новее, и не подгоняй тест.
5. Подпись: если сборка ad-hoc (`tools/bundle.py` пишет `ad-hoc`), предупреди, что на чужих Mac её заблокирует Gatekeeper, а у самого пользователя после обновления слетят «Универсальный доступ» и «Мониторинг ввода».
6. Итог для пользователя: таблица «пункт аудита → статус», новые проблемы и команда, которой их воспроизвести.
