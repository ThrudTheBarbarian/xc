#!/bin/sh
# run_win32_chrome.sh -- the `win32-chrome` gate: a window's title, subtitle, modified flag and
# document icon on Windows, read back from the real HWND under Wine.  Skips without Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v wine >/dev/null 2>&1 || { echo "== win32-chrome: skipped (wine absent) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A win64 -I "$here" -o "$work/test_win32_chrome.exe" "$here/test_win32_chrome.xc" -q
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_chrome.exe >"$work/out.txt" 2>/dev/null) || true
cat "$work/out.txt"
grep -aq '^PASS' "$work/out.txt" || { echo "== win32-chrome: FAILED =="; exit 1; }
echo "== win32-chrome: OK =="
