#!/bin/sh
# run_gtk_scroll.sh — a scroll view on GTK is a GtkScrolledWindow: it owns the offset, clicks land where
# they show, native controls scroll with it.  Skips cleanly when GTK4 or a display is absent.
# (the AppKit flow), the test links in-house against it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-scroll: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-scroll: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_scroll.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_round" -q 2>/dev/null

echo "== gtk-scroll: running =="
out=$("$work/gtk_round" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-scroll: FAILED =="; exit 1; }
echo "== gtk-scroll: OK =="
