#!/bin/sh
# run_gtk_radio.sh -- radio buttons on GTK, native (GtkCheckButtons in a group, drawn round), following
# the model both ways.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-radio: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-radio: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_radio.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_pixels" -q 2>/dev/null

echo "== gtk-radio: running =="
out=$("$work/gtk_pixels" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-radio: FAILED =="; exit 1; }
echo "== gtk-radio: OK =="
