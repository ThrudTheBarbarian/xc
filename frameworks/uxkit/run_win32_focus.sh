#!/bin/sh
# Keyboard focus traversal + the default button on the Win32 backend, under Wine.  Exercises the
# NEUTRAL tab-ring (UXWindow.moveFocus) and the app-declared default button (§5) with no Win32-
# specific focus code: a field that doesn't consume a key lets it climb the responder chain to
# the window, which turns Tab into focus movement and Return into firing the default button.
# Tab/Return arrive as ordinary WM_CHARs, so the driver needs nothing beyond the WM_CHAR decode.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_focus.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-focus: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-focus: compiling focus traversal on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_focus.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-focus: launching under Wine (Tab moves focus, Return fires the default button) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_focus.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_focus.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-focus (Wine): PASS — the neutral tab-ring works on a second backend =="
else
    echo "== win32-focus (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
