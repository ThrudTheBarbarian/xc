#!/bin/sh
# make win32-multiwindow — closing a SECONDARY window must not quit the app (only the last window does).
# Regression guard for the driver's WM_DESTROY -> PostQuitMessage bug (the colour-picker Select crash).
# Builds a real PE .exe, runs it under Wine, checks the sentinels.  Skips cleanly when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-multiwindow: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-multiwindow: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_multiwindow.exe" "$here/test_win32_multiwindow.xc" -q 2>/dev/null

echo "== win32-multiwindow: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_multiwindow.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_multiwindow.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-multiwindow (Wine): PASS — a secondary window closes without quitting the app =="
else
    echo "== win32-multiwindow (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
