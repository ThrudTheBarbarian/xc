#!/bin/sh
# The native ToolbarWindow32 controls on the Win32 backend, under Wine.  UXSegmentedControl realizes
# as a check-group (Win32 enforces the radio/toggle exclusion) and UXToolbar as a button row; both
# route their buttons' WM_COMMAND back through the neutral action.  The test fetches each toolbar
# child by control id and synthesises the OS's button clicks.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_toolbar.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-toolbar: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-toolbar: compiling native toolbar/segmented on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_toolbar.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-toolbar: launching under Wine (synthesised button clicks route to the neutral model) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_toolbar.exe 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q "^PASS: native ToolbarWindow32 routes segmented + toolbar clicks$"; then
    echo "== win32-toolbar (Wine): PASS — native segmented + toolbar on a second backend =="
else
    echo "== win32-toolbar (Wine): FAIL =="
    exit 1
fi
