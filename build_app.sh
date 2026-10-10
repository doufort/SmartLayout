#!/bin/bash
# Собирает SmartLayout.app в папке build/.
#   ./build_app.sh          — только собрать
#   ./build_app.sh install  — собрать, поставить в /Applications и запустить
#   ./build_app.sh dmg      — собрать и упаковать в build/SmartLayout-<версия>.dmg
#
# Переменные:
#   VERSION=1.2            номер версии (по умолчанию 1.1), BUILD_NUMBER — номер сборки (по умолчанию 2)
#   UNIVERSAL=0|1|auto     сборка для Apple Silicon и Intel; auto (по умолчанию) — если установлен Xcode
#   SIGN_ID="…"            чем подписывать: "Developer ID Application: Имя (TEAMID)" или имя своего
#                          сертификата из Связки ключей. По умолчанию "-" (ad-hoc): тогда после каждой
#                          пересборки macOS заново спрашивает разрешения «Универсальный доступ».
#   NOTARY_PROFILE=имя     профиль `xcrun notarytool store-credentials`: с ним `dmg` ещё и нотаризует
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SmartLayout.app
VERSION="${VERSION:-1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
SIGN_ID="${SIGN_ID:--}"
UNIVERSAL="${UNIVERSAL:-auto}"
if [ "$UNIVERSAL" = "auto" ]; then
  # Сборка сразу под две архитектуры работает только с полным Xcode, не с Command Line Tools.
  if xcodebuild -version >/dev/null 2>&1; then UNIVERSAL=1; else UNIVERSAL=0; fi
fi

BUILD_ARGS=(-c release)
if [ "$UNIVERSAL" = "1" ]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/SmartLayout" "$APP/Contents/MacOS/SmartLayout"
cp Resources/*.txt Resources/*.json Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SmartLayout</string>
  <key>CFBundleDisplayName</key><string>SmartLayout</string>
  <key>CFBundleIdentifier</key><string>com.dmitry.smartlayout</string>
  <key>CFBundleExecutable</key><string>SmartLayout</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Фоновый агент: запуск при входе и перезапуск после сбоя (но не после «Выхода» из меню).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/com.dmitry.smartlayout.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dmitry.smartlayout.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/SmartLayout</string>
  <key>AssociatedBundleIdentifiers</key><array><string>com.dmitry.smartlayout</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

# Hardened runtime нужен для нотаризации и ничему в приложении не мешает.
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"
echo "Готово: $APP ($(lipo -archs "$APP/Contents/MacOS/SmartLayout"), подпись: $SIGN_ID)"

case "${1:-}" in
  install)
    launchctl bootout "gui/$(id -u)/com.dmitry.smartlayout.agent" 2>/dev/null || true
    pkill -x SmartLayout 2>/dev/null || true
    rm -rf /Applications/SmartLayout.app
    cp -R "$APP" /Applications/
    open /Applications/SmartLayout.app
    echo "Установлено в /Applications и запущено"
    ;;
  dmg)
    DMG="build/SmartLayout-$VERSION.dmg"
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname SmartLayout -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    if [ "$SIGN_ID" != "-" ]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    fi
    echo "Готово: $DMG"
    ;;
esac
