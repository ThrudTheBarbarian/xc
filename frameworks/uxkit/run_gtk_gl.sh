#!/bin/sh
# The GTK GL SURFACE (`gtk-gl`).  Sibling of run_win32_gl.sh: the driver owns the
# surface (a real GtkGLArea, placed below the cairo drawing area), sets the viewport
# from the widget's pixel size, and presents; the app owns the renderer and reaches the
# entry points through glProc.  Checks the plumbing a renderer depends on -- a kind, a
# context, a driver-set viewport, a colour drawn and read back, a clean swap, no
# fallback to drawRect once there is a context, and a safe destroy/recreate -- and not
# a shader draw, which is the harness's on this backend.  Skips cleanly when GTK4 or a
# display is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-gl: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-gl: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_gl.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_gl" -q 2>/dev/null

echo "== gtk-gl: running (surface, context, viewport, a drawn pixel, a clean close) =="
out=$("$work/gtk_gl" 2>&1 | grep -v Warning) || true
printf '%s\n' "$out"

fail=0
for want in 'glKind=2' 'version ' 'viewport ' 'pixel 64 128 191 255' '^PASS\|^SKIP'; do
  printf '%s\n' "$out" | grep -q "$want" || { echo "  missing: $want"; fail=1; }
done
[ "$fail" = 0 ] || { echo "== gtk-gl: FAIL =="; exit 1; }
echo "== gtk-gl: OK =="
