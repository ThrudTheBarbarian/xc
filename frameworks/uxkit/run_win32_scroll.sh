#!/bin/sh
# Scrolling on the Win32 backend, under Wine.  The neutral layoutFor subtracts the driver's scroll
# offset, so the tree and hit-testing scroll together (§11); the Win32 driver provides the offset
# from a native WS_VSCROLL bar.  A marker at y=300 in a 200px window comes to y=100 after a 200px
# scroll, where a click lands on it.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_scroll.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-scroll: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-scroll: compiling scrolling on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_scroll.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-scroll: launching under Wine (tree + hit-testing scroll with the offset) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_scroll.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_scroll.out")
if [ "$got" = "$exp" ]; then echo "== win32-scroll (Wine): PASS — scrolling on a second backend =="
else echo "== win32-scroll (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
