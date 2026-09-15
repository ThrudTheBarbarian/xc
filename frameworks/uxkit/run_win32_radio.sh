#!/bin/sh
# Radio buttons (mutual exclusion) on the Win32 backend, under Wine.  UXRadioButton is custom-
# drawn; the exclusion is pure UXRadioGroup logic.  Two posted clicks select radio 0 then radio
# 2; the group leaves exactly one selected.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_radio.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-radio: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-radio: compiling radio buttons on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_radio.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-radio: launching under Wine (mutual exclusion in a group) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_radio.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_radio.out")
if [ "$got" = "$exp" ]; then echo "== win32-radio (Wine): PASS — mutual exclusion on a second backend =="
else echo "== win32-radio (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
