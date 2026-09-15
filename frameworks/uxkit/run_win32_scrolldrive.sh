#!/bin/sh
# make win32-scrolldrive — the toolkit must be able to scroll a NATIVE scroll container from code.
# scrollsNatively() is true here, and UXScrollView used to answer that by doing nothing at all, so
# programmatic scrolling was a silent no-op on Win32 and AppKit.  Asserts against GetScrollPos on the
# real UXScroll32 child, not the model.  Skips when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-scrolldrive: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-scrolldrive: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_scrolldrive.exe" "$here/test_win32_scrolldrive.xc" -q 2>/dev/null
echo "== win32-scrolldrive: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_scrolldrive.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: the toolkit drives the native scroll container$'; then
    echo "== win32-scrolldrive (Wine): PASS — code can scroll the native container =="
else
    echo "== win32-scrolldrive (Wine): FAIL =="; exit 1
fi
