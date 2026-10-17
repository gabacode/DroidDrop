#!/bin/bash
# Builds build/DroidDrop.app
# --universal builds for Apple silicon and Intel (needs Xcode). VERSION=x.y sets the app version.
set -euo pipefail
cd "$(dirname "$0")"

ARGS=(-c release)
if [ "${1:-}" = "--universal" ]; then
    ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/DroidDrop"

if [ ! -f build/AppIcon.icns ]; then
    mkdir -p build/AppIcon.iconset
    swift Scripts/make-icon.swift build/icon-1024.png
    for px in 16 32 128 256 512; do
        sips -z $px $px build/icon-1024.png --out build/AppIcon.iconset/icon_${px}x${px}.png >/dev/null
        sips -z $((px * 2)) $((px * 2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${px}x${px}@2x.png >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    rm -rf build/AppIcon.iconset
fi

APP=build/DroidDrop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DroidDrop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
