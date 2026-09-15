#!/bin/sh
# The M1 payoff: the REAL neutral UXKit layer (UXWindow + UXView + UXViewTree, unchanged) running
# on the Win32 backend (UXWin32Driver) under Wine.  Where run_win32.sh built a self-contained
# seed because the neutral classes still named GEM types, this builds the ACTUAL toolkit: the
# gap list in run_win32.sh's header is closed — the OBJECT[] structure lives in the driver,
# UXGraphics is a swappable protocol (GDI here), and no GEM type reaches the neutral layer.
#
# Paint flows backend -> the neutral seam -> app code (WM_PAINT -> ux_window_draw -> treeDraw
# -> ux_userdraw -> Canvas.drawRect, via GDI).  A click routes through the SAME tree.hitTest
# the GEM backend uses.  Headless-deterministic: forces one paint, injects one click, checks
# the sentinels.  Skips cleanly when wine is absent.
#
#   xcc -A win64 -> a real PE .exe; run under Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_real.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-real: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-real: compiling the REAL neutral layer ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_real.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-real: launching under Wine (neutral UXWindow + UXView on UXWin32Driver) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_real.exe 2>/dev/null)
printf '%s\n' "$got"                       # show it actually running

exp=$(cat "$here/expected_win32_real.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-real (Wine): PASS — the neutral UXKit layer runs on a second backend =="
else
    echo "== win32-real (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
