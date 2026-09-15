#!/bin/sh
# run_gtk_alert.sh — the GTK modal-alert gate (`gtk-alert`): a real
# GtkAlertDialog behind a nested GMainLoop, auto-cancelled for determinism.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-alert: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-alert: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_alert.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_alert" -q 2>/dev/null

echo "== gtk-alert: running =="
out=$("$work/gtk_alert" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-alert: FAILED =="; exit 1; }
echo "== gtk-alert: OK =="
