#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${1:-"$ROOT/dist/Token Usage Monitor.app"}
APP_VERSION=${APP_VERSION:-}
BUILD_NUMBER=${BUILD_NUMBER:-}
EXECUTABLE="$APP/Contents/MacOS/TokenMonitor"

test -x "$EXECUTABLE"
test "$(plutil -extract CFBundleDisplayName raw -o - "$APP/Contents/Info.plist")" = "Token Usage Monitor"
test "$(plutil -extract LSUIElement raw -o - "$APP/Contents/Info.plist")" = "true"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")" = "14.0"
if [ -n "$APP_VERSION" ]; then
    test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$APP_VERSION"
fi
if [ -n "$BUILD_NUMBER" ]; then
    test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = "$BUILD_NUMBER"
fi

ARCHITECTURES=$(lipo -archs "$EXECUTABLE")
printf ' %s ' "$ARCHITECTURES" | grep -q ' arm64 '
printf ' %s ' "$ARCHITECTURES" | grep -q ' x86_64 '
codesign --verify --deep --strict "$APP"
echo "Verified universal app: $APP ($ARCHITECTURES)"
