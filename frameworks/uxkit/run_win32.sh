#!/bin/sh
# The Win32 backend demo for UXKit — a native window + a custom view + a click routed through
# the neutral UXView path (M1 / Spike 1, doc/XTG-MULTIPLATFORM.md).  HWND = opaque handle,
# GWLP_USERDATA = reverse map, WndProc = the driver.  Headless-deterministic: it forces a
# paint and injects a click, and the overrides print sentinels — so `make win32` recompiles
# from source, launches it under Wine, SHOWS it run, and checks the sentinels.  Skips
# cleanly when wine is absent.
#
#   xcc -A win64 -> a real PE .exe; run under Wine.
#
# `xcc` compiles the whole #import graph in one invocation, so this builds "all the files
# necessary" as the demo grows; -I keeps local imports resolving.
#
# GAP to the real M1 (what makes the ACTUAL UXKit neutral layer win64-portable — this demo
# carries a self-contained neutral mini-layer until then):
#   - relocate the OBJECT[] structure into the driver (UXViewTree stops naming GEM OBJECT);
#   - make UXContext/UXGraphics a swappable protocol (GDI here vs VDI on GEM);
#   - neutralise the remaining GEM types (theme, gfx_surface) out of the neutral layer.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32: compiling $srcs for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32: launching the demo under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32.exe 2>/dev/null)
printf '%s\n' "$got"                       # show the demo actually running

exp=$(cat "$here/expected_win32.out")
if [ "$got" = "$exp" ]; then
    echo "== win32 (Wine): PASS =="
else
    echo "== win32 (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
