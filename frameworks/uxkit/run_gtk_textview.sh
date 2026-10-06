#!/bin/sh
# run_gtk_textview.sh — the gtk-textview gate: UXTextView as a native GtkTextView (content as
# attributed runs, the selection, styles, alignment, typing, emoji, undo and redo).  Skips cleanly
# when GTK4 or a display is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-textview: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-textview: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_textview.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_textview" -q 2>/dev/null

echo "== gtk-textview: running =="
out=$("$work/gtk_textview" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-textview: FAILED =="; exit 1; }
echo "== gtk-textview: OK =="
