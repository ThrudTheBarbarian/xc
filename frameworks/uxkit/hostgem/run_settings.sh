#!/bin/bash
# run_settings.sh — UXKit's settings in the XTOS SQLite registry (make gem-settings).
#
# Two runs of the same arm64 client: the first writes preferences through UXKeyValueStore, the
# second — a fresh process — must read them all back.  Between them the SQL is dumped, because the
# claim being made is not just "it persisted" but "it persisted INTO THE SYSTEM REGISTRY, in a
# settings table alongside the desktop's own deskPrefs".  No gemd and no window: the settings seam
# is the only part of the AES that needs neither.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
xcc=${XCC:-xcc}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
DB="$work/Registry.db"

echo "== building the gem stack + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the settings client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$UXKit/test_gem_settings.xc" -o "$work/test_gem_settings" \
    || { echo "client build failed"; exit 1; }

# Seed a REAL registry, so this proves the settings table lands in the desktop's own database
# without disturbing what is already in it.
SEED=$UX_GEM_DIR/../loader/test/freertos/Registry.sql
if [ -f "$SEED" ]; then sqlite3 "$DB" < "$SEED" 2>/dev/null || true; fi

echo "== pass 1 (write) =="
UX_SETTINGS_PASS=write UX_SETTINGS_DB="$DB" DYLD_LIBRARY_PATH=/tmp "$work/test_gem_settings" 2>&1 | sed 's/^/  /'

echo "== the registry, as SQL =="
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "SELECT domain,key,value FROM settings ORDER BY domain,key" | sed 's/^/  /'
    echo "  -- the desktop's own prefs, untouched:"
    sqlite3 "$DB" "SELECT key,value FROM deskPrefs" 2>/dev/null | sed 's/^/  /'
fi

echo "== pass 2 (a fresh process reads it back) =="
got=$(UX_SETTINGS_PASS=read UX_SETTINGS_DB="$DB" DYLD_LIBRARY_PATH=/tmp "$work/test_gem_settings" 2>&1)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: settings persist in the system registry$'; then
    echo "== gem-settings: PASS — preferences live in the SQLite registry =="
else
    echo "== gem-settings: FAIL =="; exit 1
fi
