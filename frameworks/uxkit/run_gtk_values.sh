#!/bin/sh
# run_gtk_values.sh — the gtk-values gate: native GTK controls follow their models once they exist,
# without firing their actions.  Skips cleanly when GTK4 or a display is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-values: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-values: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_values.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_round" -q 2>/dev/null

echo "== gtk-values: running =="
out=$("$work/gtk_round" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-values: FAILED =="; exit 1; }
echo "== gtk-values: OK =="
