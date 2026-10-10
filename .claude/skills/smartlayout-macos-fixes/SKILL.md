---
name: smartlayout-macos-fixes
description: Как править Swift-код SmartLayout (Sources/SmartLayout) — перехват клавиш, движок исправлений, обучение, ИИ-подсказки, буфер обмена — а также защиты из docs/AUDIT.md (исключения по приложениям, поля паролей, таблица раскладки через UCKeyTranslate, приватность ИИ, сборка и подпись). Используй при любой правке *.swift или build_app.sh.
---

# Правки Swift-кода SmartLayout

## Карта кода

| Файл | За что отвечает |
|---|---|
| `KeyboardMonitor.swift` | event tap: буфер слова, границы слов, раннее определение раскладки, отмена по Backspace |
| `CorrectionEngine.swift` | решение «не та раскладка / опечатка» (`evaluate`, `evaluatePrefix`, `looksRussian`) |
| `LayoutMap.swift` | таблицы QWERTY ↔ ЙЦУКЕН (модель на Python: `tools/layout_map.py` читает их из этого файла) |
| `WordStore.swift`, `LearningStore.swift` | сленг, словарь пользователя, исключения, самообучение (`learning.json`) |
| `AIClient.swift`, `AIController.swift`, `HumanStyle.swift` | запросы к LLM, разбор ответа, правило «не похоже на нейросеть» |
| `SuggestionPanel.swift` | плавающая подсказка: принять ⌥↩, вариант ⌥⇧↩, продолжение ⌥⇥, отказ Esc |
| `TextAccess.swift` | Accessibility (чтение и замена текста) и запасной путь через буфер обмена |

## Правила

- Любое исправление сопровождай тестом. Логику без UI тестируй в `Tests/SmartLayoutTests/` через XCTest, конфигурацию сборки — в `pytests/test_sources.py` или `pytests/test_bundle.py`.
- **Тесты не трогают настоящие данные пользователя.** Создавай хранилища только через `TestFiles.wordStore()` и `LearningStore(url: TestFiles.tempFile(...))`. `LearningStore()` и `WordStore()` без аргументов в тестах запрещены, это проверяет `pytests/test_sources.py`.
- Обработчик event tap должен работать быстро: никаких сетевых запросов, а синхронный `NSSpellChecker` только через кэши `CorrectionEngine`.
- Синтетические нажатия отправляй только через `KeySender` (помечены `syntheticTag`), иначе перехватчик обработает их как ваши.
- Если меняешь формат `learning.json`, новые поля декодируй через `decodeIfPresent`, иначе у пользователей обнулится выученное.
- Проверка: PostToolUse-хук запускает `swiftc -parse` для `.swift` (если `swiftc` есть) и pytest. Полные `swift build && swift test && ./build_app.sh` гоняет CI (`.github/workflows/ci.yml`, macOS). На Linux Swift-код не собрать, поэтому после пуша смотри результат CI.

## Устройство защит (не ломать)

- **Исключения по приложениям**: `AppExclusions` (`locked` — менеджеры паролей, включить нельзя; `defaults` — терминалы и IDE; значение с точкой на конце — префикс). `frontmostExcluded` кэшируется по `didActivateApplicationNotification` и проверяется на каждое нажатие в `KeyboardMonitor.handle` и в `AIController.userTyped/autoCheck`. Новое приложение добавляй в список и в `AppExclusionsTests`.
- **Поля паролей**: `IsSecureEventInputEnabled()` в начале `handle`; `wordIsSecret` (один AX-запрос `TextAccess.focusedIsSecure(timeout: 0.1)` на слово); `TextAccess.read()` и горячие клавиши ИИ не читают `AXSecureTextField`. Любой новый путь, который читает текст или отправляет его ИИ, тоже должен это проверять.
- **Таблица клавиш**: `LayoutMap.current` строится `KeyboardLayouts.table(en:ru:)` через `UCKeyTranslate` при запуске и при смене раскладки, `LayoutMap.builtIn` — запасной вариант. Если меняешь встроенные таблицы, обнови `tools/layout_map.py` (он читает их из Swift) и `KeyTableTests`.
- **Приватность**: `aiAutoCheck` и `aiReadWindow` по умолчанию `false`, включение из меню идёт через `confirmSending`. Миграция для пользователей 1.0 — `Settings.migratePrivacyDefaults` (запускается до `register(defaults:)`). Ключ не уходит по `http://` за пределы локальной сети (`AIConfig.sendsKeyInsecurely`).
- **Медленный проверщик**: `CorrectionEngine.noteDuration` и `isSlow` — раннее определение раскладки на минуту выключается. Новые синхронные вызовы `NSSpellChecker` оборачивай так же.

## Что ещё можно сделать

- **Подпись Developer ID** (нужен аккаунт пользователя): `SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=… ./build_app.sh dmg`. После этого `test_developer_id_signature` перестанет быть xfail.
- Проверка обновлений и Homebrew cask, как в RuSwitcher.
