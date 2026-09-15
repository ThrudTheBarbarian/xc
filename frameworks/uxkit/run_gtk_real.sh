#!/bin/sh
# run_gtk_real.sh — the GTK driver's bring-up gate (`gtk-real`, plan phase 1b).
# Skips cleanly when GTK4 or a display is absent.  The shim links as a dylib
# (the AppKit flow), the test links in-house against it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-real: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-real: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_real.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_real" -q 2>/dev/null

echo "== gtk-real: running =="
out=$("$work/gtk_real" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-real: FAILED =="; exit 1; }
echo "== gtk-real: OK =="
