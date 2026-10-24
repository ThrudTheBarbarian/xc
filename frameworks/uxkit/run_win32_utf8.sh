#!/bin/sh
# run_win32_utf8.sh -- the `win32-utf8` gate: UTF-8 text in titles, controls, menus and measuring
# reaches Windows as UTF-16, read back from the real controls under Wine.  Skips without Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v wine >/dev/null 2>&1 || { echo "== win32-utf8: skipped (wine absent) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A win64 -I "$here" -o "$work/test_win32_utf8.exe" "$here/test_win32_utf8.xc" -q
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_utf8.exe >"$work/out.txt" 2>/dev/null) || true
cat "$work/out.txt"
grep -aq '^PASS' "$work/out.txt" || { echo "== win32-utf8: FAILED =="; exit 1; }
echo "== win32-utf8: OK =="
