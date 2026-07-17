#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_VERSION=${APP_VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")}
BUILD_NUMBER=${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")}
APP="$ROOT/dist/Token Usage Monitor.app"
STAGING="$ROOT/.build/dmg-root"
DMG="$ROOT/dist/Token-Usage-Monitor-$APP_VERSION-universal.dmg"
CHECKSUM_FILE="$DMG.sha256"

APP_VERSION="$APP_VERSION" BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/package-app.sh"
APP_VERSION="$APP_VERSION" BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/verify-app.sh" "$APP"

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Token Usage Monitor.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG" "$CHECKSUM_FILE"
hdiutil create \
    -volname "Token Usage Monitor" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG"
hdiutil verify "$DMG"

CHECKSUM=$(shasum -a 256 "$DMG" | awk '{print $1}')
printf '%s  %s\n' "$CHECKSUM" "$(basename "$DMG")" > "$CHECKSUM_FILE"

echo "$DMG"
echo "$CHECKSUM_FILE"
