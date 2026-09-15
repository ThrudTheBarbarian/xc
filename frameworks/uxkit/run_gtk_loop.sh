#!/bin/sh
# run_gtk_loop.sh — the GTK run-loop gate (`gtk-loop`): UXApplication.run() sleeping in the GMainContext.
# Skips cleanly when GTK4 or a display is absent.  The shim links as a dylib
# (the AppKit flow), the test links in-house against it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-loop: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-loop: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_loop.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_loop" -q 2>/dev/null

echo "== gtk-loop: running =="
out=$("$work/gtk_loop" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-loop: FAILED =="; exit 1; }
echo "== gtk-loop: OK =="
