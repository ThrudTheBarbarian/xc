#!/bin/sh
# run_gtk_dnd.sh -- drags and drops on GTK: table and outline rows drag out, drops and hovers reach
# the application, the outline's item under a point is found, context menus fire their pick, and
# a window draws a line above its native controls.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-dnd: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-dnd: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_dnd.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_dnd" -q

echo "== gtk-dnd: running =="
out=$("$work/gtk_dnd" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-dnd: FAILED =="; exit 1; }
echo "== gtk-dnd: OK =="
