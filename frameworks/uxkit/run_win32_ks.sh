#!/bin/sh
# make win32 — the UXKit kitchen-sink on the Win32 backend, under Wine.  Builds a real PE .exe and runs
# it: the SAME neutral app as make mac / make a9, on UXWin32Driver.  Resize the window (springs run
# in the neutral layer), click the widgets, use the menu.  Skips cleanly if wine is absent.
#
# The macOS demos close themselves after a moment (demo_autoquit.xc); the Win32 driver has no timer
# to hang that off yet, so this bounds the run instead — the window cannot camp on the screen and
# hold the keyboard focus.  --stay waits for you to close it, which is what poking wants.
set -e
case "${1:-}" in
  --stay) UX_KS_WAIT=0 ;;
  --wait) UX_KS_WAIT=${2:-30} ;;
esac
UX_KS_WAIT=${UX_KS_WAIT:-15}
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32: compiling the kitchen-sink for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/ks_win32.exe" "$here/ks_win32.xc" -q 2>/dev/null

if [ "$UX_KS_WAIT" = 0 ]; then
    echo "== win32: launching under Wine — close the window to exit =="
    (cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" wine ks_win32.exe 2>/dev/null)
else
    echo "== win32: launching under Wine — up for ${UX_KS_WAIT}s (--stay to close it yourself) =="
    (cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout "$UX_KS_WAIT" wine ks_win32.exe 2>/dev/null) || true
fi
echo "== win32: done =="
