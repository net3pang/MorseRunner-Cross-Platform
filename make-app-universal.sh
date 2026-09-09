#!/bin/bash
# Build the MorseRunner macOS app bundle from the SwiftPM build (Universal Binary).
set -e
cd "$(dirname "$0")"

APP="dist/MorseRunner.app"
# Build into a staging directory.  The old script deleted the existing app
# before invoking SwiftPM; when SwiftPM failed, that left an empty directory
# which Finder reports as an invalid/unopenable application.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/MorseRunner.app.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

# SwiftPM's output layout has changed between toolchain versions.  Ask
# SwiftPM for the bin directory instead of assuming .build/<triple>/release.
build_slice() {
    local triple="$1"
    local build_path="$2"
    local bin_path
    if ! bin_path="$(swift build -c release --product MorseRunner --triple "$triple" \
        --build-path "$build_path" --show-bin-path)"; then
        return 1
    fi
    if ! swift build -c release --product MorseRunner --triple "$triple" \
        --build-path "$build_path"; then
        return 1
    fi
    if [[ ! -x "$bin_path/MorseRunner" ]]; then
        echo "SwiftPM did not produce $bin_path/MorseRunner" >&2
        return 1
    fi
    SLICE_BIN="$bin_path/MorseRunner"
}

echo "Building x86_64 (Intel) slice..."
if ! build_slice x86_64-apple-macosx14.0 .build/universal-x86_64; then
    echo "Failed to build x86_64 slice; app was not modified." >&2
    exit 1
fi
X86_BIN="$SLICE_BIN"

echo "Building arm64 (Apple Silicon) slice..."
if ! build_slice arm64-apple-macosx14.0 .build/universal-arm64; then
    echo "Failed to build arm64 slice; app was not modified." >&2
    exit 1
fi
ARM_BIN="$SLICE_BIN"

echo "Combining into Universal Binary using lipo..."
mkdir -p .build/universal
lipo -create \
    "$X86_BIN" \
    "$ARM_BIN" \
    -output "$STAGE/Contents/MacOS/MorseRunner"

cp -R Resources/. "$STAGE/Contents/Resources/"

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
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/MorseRunner.icns"
rm -rf "$ICONSET"

cat > "$STAGE/Contents/Info.plist" << 'PLIST'
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
    <string>1.2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
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

chmod +x "$STAGE/Contents/MacOS/MorseRunner"

# Refuse to publish a malformed bundle.  These checks also make failures
# obvious in CI instead of producing an app that cannot be opened.
test -x "$STAGE/Contents/MacOS/MorseRunner"
test -f "$STAGE/Contents/Info.plist"
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null
lipo -info "$STAGE/Contents/MacOS/MorseRunner" | grep -q 'arm64'
lipo -info "$STAGE/Contents/MacOS/MorseRunner" | grep -q 'x86_64'

# Sign and verify while the bundle is still in staging.  Some synced folders
# attach Finder metadata immediately after a move; that metadata can make a
# post-move `codesign --verify` report a false failure.
xattr -cr "$STAGE" 2>/dev/null || true
codesign --force --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

rm -rf "$APP"
mv "$STAGE" "$APP"
trap - EXIT
# Clear metadata that the destination directory may attach during the move,
# then sign the exact bundle that will be opened by Finder.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Successfully built Universal App: $APP"
