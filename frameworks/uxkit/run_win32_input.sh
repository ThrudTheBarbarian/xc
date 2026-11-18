#!/bin/sh
# make win32-input -- Win32 input as the toolkit hears it (test_win32_input.xc): the middle button,
# the keys with no character, key releases and the wheel both ways, posted to the window and decoded
# by the driver.  Under Wine; skips cleanly without it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-input: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-input: compiling test_win32_input for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_input.exe" "$here/test_win32_input.xc" -q
echo "== win32-input: running under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_input.exe 2>/dev/null)
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== win32-input: FAIL =="; exit 1; }
echo "== win32-input: OK =="
