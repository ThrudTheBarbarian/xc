#!/bin/sh
# The Win32 GL SURFACE, under Wine.  The seam puts the surface on the DRIVER and the
# renderer on the app; this gate drives that from the app side and checks the parts a
# renderer depends on and nothing else does -- the backend answers a GL kind, makeGL
# makes a context and is idempotent, glProc resolves the entry points, the DRIVER sets
# the viewport from the client rect, a colour drawn through the entry points lands on the
# drawable (read back), the swap is clean, a GL view with a context does NOT fall back to
# drawRect, and destroy/recreate is safe.
#
# The VERSION line is printed but NOT matched: this machine's Wine offers a 2.1
# compatibility context, and a different Wine or driver would say something else.  What
# the gate proves is the surface plumbing -- pixel format, context, viewport, swap,
# readback -- and NOT a core-profile 3.3 shader draw, which no Wine on this box can give.
# That is why the stable lines are matched by marker and the version is left free.
#
#   xcc -A win64 -> a real PE .exe; run under Wine.  Skips cleanly when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_gl.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-gl: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-gl: compiling the GL surface ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_gl.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-gl: launching under Wine (surface, context, viewport, a drawn pixel, a clean close) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine test_win32_gl.exe 2>/dev/null)
printf '%s\n' "$got"

fail=0
for want in 'glKind=2' 'version ' 'viewport 0 0 640 400' 'pixel 64 128 191 255' '^PASS'; do
  printf '%s\n' "$got" | grep -q "$want" || { echo "  missing: $want"; fail=1; }
done
[ "$fail" = 0 ] || { echo "== win32-gl (Wine): FAIL =="; exit 1; }
echo "== win32-gl (Wine): OK =="
