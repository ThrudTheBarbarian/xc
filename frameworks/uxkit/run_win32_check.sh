#!/bin/sh
# A checkbox on the Win32 backend, under Wine.  UXCheckbox is a custom-drawn neutral control
# (no native checkbox on GEM or a bare Win32 window), so the same class toggles identically on
# every backend.  Two posted clicks toggle it on then off, each firing target/action.  Skips if
# wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_check.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-check: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-check: compiling a checkbox on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_check.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-check: launching under Wine (two clicks toggle a custom-drawn control) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_check.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_check.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-check (Wine): PASS — a custom-drawn control on a second backend =="
else
    echo "== win32-check (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
