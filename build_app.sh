#!/bin/bash
# Собирает SmartLayout.app в папке build/.
# ./build_app.sh install — ещё и ставит в /Applications и запускает.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SmartLayout.app
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SmartLayout" "$APP/Contents/MacOS/SmartLayout"
cp Resources/*.txt Resources/*.json "$APP/Contents/Resources/"

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
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
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

codesign --force --deep --sign - "$APP"
echo "Готово: $APP"

if [ "${1:-}" = "install" ]; then
  launchctl bootout "gui/$(id -u)/com.dmitry.smartlayout.agent" 2>/dev/null || true
  pkill -x SmartLayout 2>/dev/null || true
  rm -rf /Applications/SmartLayout.app
  cp -R "$APP" /Applications/
  open /Applications/SmartLayout.app
  echo "Установлено в /Applications и запущено"
fi
