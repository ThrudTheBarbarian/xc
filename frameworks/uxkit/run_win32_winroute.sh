#!/bin/sh
# A click on a SECOND window must route to that window's view, not the first — the old Win32
# windowAtPoint stub always returned window 1, so every click (and hence a drag on a secondary
# window) went to the wrong tree.  Two windows, a click posted to the second, assert it landed there.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-winroute: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-winroute: compiling multi-window click routing for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/wr.exe" "$here/test_win32_winroute.xc" -q 2>/dev/null

echo "== win32-winroute: launching under Wine (click the 2nd window, check it routes there) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine wr.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q "^PASS: click routed to the window it landed on$"; then
    echo "== win32-winroute (Wine): PASS — clicks route to the right window on a second backend =="
else
    echo "== win32-winroute (Wine): FAIL =="
    exit 1
fi
