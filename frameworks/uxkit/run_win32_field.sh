#!/bin/sh
# Live text editing on the Win32 backend, under Wine.  A form with a text field, driven through
# the neutral run loop: a posted click focuses the field, posted WM_CHARs travel driver.nextEvent
# -> UXEventKeyDown -> UXTextField.keyDown -> driver.editText (the driver IS the edit engine on
# Win32, as objc_edit is on GEM).  "Hi", Backspace, "o" -> "Ho".  Skips cleanly if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_field.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-field: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-field: compiling a live text field on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_field.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-field: launching under Wine (type through the real message pump) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_field.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_field.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-field (Wine): PASS — live text editing on a second backend =="
else
    echo "== win32-field (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
