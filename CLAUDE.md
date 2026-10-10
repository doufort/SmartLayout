# SmartLayout

Приложение в строке меню macOS (Swift, SwiftPM, macOS 13+): автопереключение раскладки EN↔RU, исправление опечаток, проверка текста через LLM. Подробности для пользователя: README.md. Результаты аудита и открытые проблемы: docs/AUDIT.md.

## Структура

- `Sources/SmartLayout/` — код приложения, `Tests/SmartLayoutTests/` — XCTest (`swift test`, только на Mac).
- `Resources/` — словари (`slang_*`, `typos_*`) и `style_profile.json`, копируются в бандл скриптом `build_app.sh`.
- `pytests/` — pytest: словари, исходники и build-скрипт, а также релизная сборка из `dist/*.dmg`. Работает на Linux.
- `tools/` — `check_dicts.py` (валидатор словарей), `bundle.py` (разбор .app/.dmg без macOS), `swift_source.py` и `layout_map.py` (константы, прочитанные из Swift-исходников), `ai_load_test.py` (нагрузочный тест YandexGPT, нужны ключи).
- `dist/` — выпущенные сборки. Не редактировать (это блокирует хук).

## Команды

```bash
python3 -m pytest                         # быстро, без Mac
python3 tools/check_dicts.py              # только словари
python3 tools/bundle.py dist/<file>.dmg   # отчёт по сборке
swift build && swift test                 # на Mac
./build_app.sh [install]                  # сборка .app (VERSION=…, UNIVERSAL=1)
```

## Правила

- Скиллы проекта: `smartlayout-dictionaries` (правка словарей), `smartlayout-macos-fixes` (правка Swift-кода), `smartlayout-release-audit` (проверка новой сборки).
- Хуки (`.claude/settings.json`): после каждой правки проверяются словари и build_app.sh, на Mac выполняется `swiftc -parse`, затем прогоняется pytest. Правки в `dist/`, `build/` и `.build/` запрещены. Если хук вернул ошибку, исправь причину, а не обходи хук.
- Каждое исправление бага сопровождается тестом. Тест на ещё не исправленную проблему помечается `xfail(strict=True, reason="AUDIT #N: …")`.
- Тесты не должны трогать `~/Library/Application Support/SmartLayout` и настоящие UserDefaults (см. `Tests/SmartLayoutTests/TestSupport.swift`).
- В этом окружении Swift-код не собрать: после пуша смотри CI (`.github/workflows/ci.yml`, job на macOS).
