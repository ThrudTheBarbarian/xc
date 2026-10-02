#!/bin/sh
# run_gtk_menu.sh -- the menu bar on GTK (a GtkPopoverMenuBar over a GMenu): picks fire, ticks and
# greying show in the actions, every window has the bar, the content keeps its size.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-menu: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-menu: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_menu.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_pixels" -q 2>/dev/null

echo "== gtk-menu: running =="
out=$("$work/gtk_pixels" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-menu: FAILED =="; exit 1; }
echo "== gtk-menu: OK =="
