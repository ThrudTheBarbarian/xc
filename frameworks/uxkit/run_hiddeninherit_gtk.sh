#!/bin/sh
# run_hiddeninherit_gtk.sh — the GTK half of the hidden-inheritance gate.
# Same assertions as the AppKit one; only the driver differs, which is the
# point: the fix had to land on every backend, not just the one it was found on.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== hiddeninherit-gtk: no compiler; set XCC =="; exit 2; }
pkg-config --exists gtk4 2>/dev/null || { echo "== hiddeninherit-gtk: skipped (no gtk4) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
   $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_hiddeninherit_gtk.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/hi_gtk" -q
out=$("$work/hi_gtk" 2>&1 | grep -v Warning) || true
echo "$out" | tail -3
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== hiddeninherit-gtk: FAILED =="; exit 1; }
echo "== hiddeninherit-gtk: OK =="
