#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Token Usage Monitor.app"
DESTINATION="$HOME/Applications/Token Usage Monitor.app"
LEGACY_DESTINATION="$HOME/Applications/Token Monitor.app"

if [ ! -d "$APP" ]; then
    "$ROOT/scripts/package-app.sh"
fi

mkdir -p "$HOME/Applications"
rm -rf "$DESTINATION"
ditto "$APP" "$DESTINATION"
rm -rf "$LEGACY_DESTINATION"
echo "$DESTINATION"
