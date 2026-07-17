#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Token Usage Monitor.app"
LEGACY_APP="$ROOT/dist/Token Monitor.app"
APP_VERSION=${APP_VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")}
BUILD_NUMBER=${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")}
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

SWIFT=$(xcrun --find swift)

if ! printf '%s\n' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$'; then
    echo "APP_VERSION must be a semantic version such as 1.0.0" >&2
    exit 1
fi
if ! printf '%s\n' "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
    echo "BUILD_NUMBER must be a positive integer" >&2
    exit 1
fi

build_architecture() {
    architecture=$1
    scratch="$ROOT/.build/$architecture"
    cache="$ROOT/.build/package-cache-$architecture"
    module_cache="$scratch/module-cache"
    clang_cache="$scratch/clang-module-cache"

    CLANG_MODULE_CACHE_PATH="$clang_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    "$SWIFT" build \
        --disable-sandbox \
        --scratch-path "$scratch" \
        --cache-path "$cache" \
        -c release \
        --product TokenMonitor \
        --triple "$architecture-apple-macosx14.0" \
        --package-path "$ROOT" >&2

    CLANG_MODULE_CACHE_PATH="$clang_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    "$SWIFT" build \
        --disable-sandbox \
        --scratch-path "$scratch" \
        --cache-path "$cache" \
        -c release \
        --show-bin-path \
        --triple "$architecture-apple-macosx14.0" \
        --package-path "$ROOT"
}

ARM64_BIN_PATH=$(build_architecture arm64)
X86_64_BIN_PATH=$(build_architecture x86_64)

rm -rf "$APP" "$LEGACY_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    "$ARM64_BIN_PATH/TokenMonitor" \
    "$X86_64_BIN_PATH/TokenMonitor" \
    -output "$APP/Contents/MacOS/TokenMonitor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/TokenMonitor"
codesign --force --deep --sign - "$APP"

echo "$APP"
