#!/bin/sh
# make win32-scrollpaint — a programmatic repaint must reach inside a native scroll container.
# The UXScroll32 child is its own HWND, so invalidating the window's client area misses it: the driver
# tracks the live containers and invalidates them too.  Dirties a view in the document from code (no
# click) both in view and while scrolled out of view; each must produce a fresh drawRect.  Skips when
# wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-scrollpaint: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-scrollpaint: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_scrollpaint.exe" "$here/test_win32_scrollpaint.xc" -q 2>/dev/null
echo "== win32-scrollpaint: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_scrollpaint.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^scrollRepaintReaches=1$'; then
    echo "== win32-scrollpaint (Wine): PASS — app-driven repaints reach the container =="
else
    echo "== win32-scrollpaint (Wine): FAIL — the container went unpainted =="; exit 1
fi
