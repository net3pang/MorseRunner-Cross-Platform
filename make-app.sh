#!/bin/bash
# Build the MorseRunner macOS app bundle from the SwiftPM build.
set -e
cd "$(dirname "$0")"

APP="dist/MorseRunner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# build only the app product (the test target needs @testable, debug only),
# as a universal binary for both Apple Silicon (arm64) and Intel (x86_64).
swift build -c release --arch arm64 --arch x86_64 --product MorseRunner

cp .build/apple/Products/Release/MorseRunner "$APP/Contents/MacOS/MorseRunner"
cp -R Resources/* "$APP/Contents/Resources/"

# ---- app icon (generated from tools/make-icon.swift)
ICON_PNG=".build/MorseRunner-icon.png"
swift tools/make-icon.swift "$ICON_PNG" >/dev/null
ICONSET=".build/MorseRunner.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/MorseRunner.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Morse Runner</string>
    <key>CFBundleDisplayName</key>
    <string>Morse Runner for macOS</string>
    <key>CFBundleIdentifier</key>
    <string>org.morserunner.macos</string>
    <key>CFBundleVersion</key>
    <string>1.2.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.1</string>
    <key>CFBundleExecutable</key>
    <string>MorseRunner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>MorseRunner</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Morse Runner plays simulated CW audio through your speakers.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
