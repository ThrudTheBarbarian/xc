#!/bin/sh
# run_win32_files.sh -- the `win32-files` gate: UXKit's open and save panels on Windows are the
# common dialogs GetOpenFileName and GetSaveFileName, answered as a user would (under Wine).  Skips without wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v wine >/dev/null 2>&1 || { echo "== win32-files: skipped (wine absent) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A win64 -I "$here" -o "$work/test_win32_files.exe" "$here/test_win32_files.xc" -q
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_files.exe >"$work/out.txt" 2>/dev/null) || true
cat "$work/out.txt"
grep -aq '^PASS' "$work/out.txt" || { echo "== win32-files: FAILED =="; exit 1; }
echo "== win32-files: OK =="
