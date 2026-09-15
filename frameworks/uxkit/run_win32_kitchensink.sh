#!/bin/sh
# A whole form on the Win32 backend, under Wine — the session's capstone.  A menu, a label, a
# text field, a checkbox, a radio group and a Submit button, composed in one window and driven
# end to end through the neutral run loop: type a name, tick Subscribe, pick SMS, click Submit,
# then File>Quit.  The controller reads every control through the neutral API.  Skips if wine absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_kitchensink.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-kitchensink: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-kitchensink: compiling a full form on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_kitchensink.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-kitchensink: launching under Wine (menu + label + field + checkbox + radios + button) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_kitchensink.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_kitchensink.out")
if [ "$got" = "$exp" ]; then echo "== win32-kitchensink (Wine): PASS — a whole form on a second backend =="
else echo "== win32-kitchensink (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
