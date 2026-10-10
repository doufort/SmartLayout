---
name: smartlayout-macos-fixes
description: Как править Swift-код SmartLayout (Sources/SmartLayout) — перехват клавиш, движок исправлений, обучение, ИИ-подсказки, буфер обмена — и закрывать открытые пункты docs/AUDIT.md (исключения по приложениям, Secure Input, раскладка Apple «Русская», universal-сборка, подпись, приватность ИИ). Используй при любой правке *.swift или build_app.sh.
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

- Любое исправление сопровождай тестом. Логику без UI тестируй в `Tests/SmartLayoutTests/` через XCTest, конфигурацию сборки — в `tests/test_sources.py` или `tests/test_bundle.py`.
- **Тесты не трогают настоящие данные пользователя.** Создавай хранилища только через `TestFiles.wordStore()` и `LearningStore(url: TestFiles.tempFile(...))`. `LearningStore()` и `WordStore()` без аргументов в тестах запрещены, это проверяет `tests/test_sources.py`.
- Обработчик event tap должен работать быстро: никаких сетевых запросов, а синхронный `NSSpellChecker` только через кэши `CorrectionEngine`.
- Синтетические нажатия отправляй только через `KeySender` (помечены `syntheticTag`), иначе перехватчик обработает их как ваши.
- Если меняешь формат `learning.json`, новые поля декодируй через `decodeIfPresent`, иначе у пользователей обнулится выученное.
- Проверка: PostToolUse-хук запускает `swiftc -parse` для `.swift` (если `swiftc` есть) и pytest. Полные `swift build && swift test && ./build_app.sh` гоняет CI (`.github/workflows/ci.yml`, macOS). На Linux Swift-код не собрать, поэтому после пуша смотри результат CI.

## Рецепты для открытых пунктов docs/AUDIT.md

**#4 Исключения по приложениям.** `Settings.excludedBundleIDs: Set<String>`. По умолчанию туда входят `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `net.kovidgoyal.kitty`, `com.github.wez.wezterm`, `com.microsoft.VSCode`, `com.apple.dt.Xcode`, `com.jetbrains.*`, `com.1password.1password`, `com.bitwarden.desktop`. Проверять `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` в начале `KeyboardMonitor.handle` (сброс буфера, пропуск события) и в `AIController.userTyped`. Добавить пункт меню «Отключить в <приложение>». После этого сними `xfail` с `test_app_exclusion_list`.

**#3 Secure Input.** В `KeyboardMonitor.handle`: `if IsSecureEventInputEnabled() { reset(); return pass }`. В `TextAccess.read()` не читать поле с `kAXSubroleAttribute == kAXSecureTextFieldSubrole`. Показывать неактивирующую плашку (`.nonactivatingPanel` и `orderFrontRegardless`, без `NSApp.activate`), как `SecureInputNotice.swift` в RuSwitcher.

**#5 Раскладка.** Таблицу строить через `UCKeyTranslate` по `kTISPropertyUnicodeKeyLayoutData` текущих источников ввода для кодов клавиш 0…50 со Shift и без него, а `LayoutMap` оставить запасным вариантом. После правки обнови `tools/layout_map.py` и тесты.

**#1 Universal.** `UNIVERSAL=1 ./build_app.sh`, проверка `lipo -archs build/SmartLayout.app/Contents/MacOS/SmartLayout`.

**#2 Подпись.** `codesign --force --options runtime --timestamp --sign "Developer ID Application: …"`, затем `xcrun notarytool submit … --wait` и `xcrun stapler staple`.

**#6 Приватность ИИ.** `aiAutoCheck` по умолчанию `false`, при первом включении спрашивать согласие. `ConversationMemory.captureScreen` вызывать только с явного согласия. Пустой `style_profile.json` в сборках для других людей.
