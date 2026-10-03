#!/bin/sh
# run_gtk_snapshot.sh -- the `gtk-snapshot` gate: UXWindow.snapshot on GTK 4: the GtkGLArea's frame,
# the 2-D views over it and the native button, whole or a region.  Skips cleanly without GTK 4.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-snapshot: skipped (no gtk4) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" -D SNAP_GTK "$here/test_snapshot.xc" -Xlinker "$work/libUXGtk.dylib" -o "$work/test_snapshot" -q
out=$("$work/test_snapshot" 2>&1 | grep -v Warning) || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== gtk-snapshot: FAILED =="; exit 1; }
echo "== gtk-snapshot: OK =="
