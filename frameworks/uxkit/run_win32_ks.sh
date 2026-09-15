#!/bin/sh
# make win32 — the UXKit kitchen-sink on the Win32 backend, under Wine.  Builds a real PE .exe and runs
# it: the SAME neutral app as make mac / make a9, on UXWin32Driver.  Resize the window (springs run
# in the neutral layer), click the widgets, use the menu.  Skips cleanly if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32: compiling the kitchen-sink for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/ks_win32.exe" "$here/ks_win32.xc" -q 2>/dev/null

echo "== win32: launching under Wine — close the window to exit =="
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" wine ks_win32.exe 2>/dev/null)
echo "== win32: done =="
