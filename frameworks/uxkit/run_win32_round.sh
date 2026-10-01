#!/bin/sh
# run_win32_round.sh -- a rounded panel (setCornerRadius + setBorderRGB) on Win32's native scroll
# container, under Wine: the window region, the framed edge, the content inside.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-round: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-round: compiling test_win32_round.xc for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_round.exe" "$here/test_win32_round.xc" -q 2>/dev/null
echo "== win32-round: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_round.exe 2>/dev/null)
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== win32-round (Wine): FAIL =="; exit 1; }
echo "== win32-round (Wine): PASS =="
