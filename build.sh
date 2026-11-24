#!/bin/zsh
# Builds "Mac Recorder.app" (menu-bar app). Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="Mac Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/MacRecorder "$APP/Contents/MacOS/MacRecorder"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ryanhelou.macrecorder</string>
  <key>CFBundleName</key><string>Mac Recorder</string>
  <key>CFBundleExecutable</key><string>MacRecorder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Mac Recorder records your voice on calls.</string>
</dict></plist>
PLIST
# Sign with a real certificate when available so macOS permissions survive rebuilds.
IDENT=$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)
codesign --force --sign "${IDENT:--}" --identifier com.ryanhelou.macrecorder "$APP"
echo "Built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP"; cp -R "$APP" /Applications/; echo "Installed to /Applications"
fi
