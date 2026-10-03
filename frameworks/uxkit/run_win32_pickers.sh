#!/bin/sh
# run_win32_pickers.sh -- the `win32-pickers` gate: UXKit's colour and font pickers on Windows are the
# common dialogs ChooseColor and ChooseFont, answered as a user would (under Wine).  Skips without wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v wine >/dev/null 2>&1 || { echo "== win32-pickers: skipped (wine absent) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A win64 -I "$here" -o "$work/test_win32_pickers.exe" "$here/test_win32_pickers.xc" -q
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_pickers.exe >"$work/out.txt" 2>/dev/null) || true
cat "$work/out.txt"
grep -aq '^PASS' "$work/out.txt" || { echo "== win32-pickers: FAILED =="; exit 1; }
echo "== win32-pickers: OK =="
