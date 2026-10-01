#!/bin/sh
# make win32-pixels -- a bitmap region drawn in a drawRect (drawPixels) on Win32, under Wine, checked as
# pixels read from the window's own DC.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-pixels: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-pixels: compiling test_win32_pixels.xc for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_pixels.exe" "$here/test_win32_pixels.xc" -q 2>/dev/null
echo "== win32-pixels: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_pixels.exe 2>/dev/null)
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== win32-pixels (Wine): FAIL =="; exit 1; }
echo "== win32-pixels (Wine): PASS =="
