#!/bin/sh
# run_gtk_glextern.sh — the gtk-glextern gate: a renderer's plain GL externs (glClear ...) act on
# GTK's context when the link names the GL library: here -framework OpenGL; on Linux,
# UX_LINUX_LIBS=-lGL sh run_gtk_linux.sh test_gtk_glextern.  Skips cleanly when GTK4 or a display is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-glextern: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-glextern: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_glextern.xc" \
    -Xlinker "$work/libUXGtk.dylib" -framework OpenGL -o "$work/gtk_round" -q 2>/dev/null

echo "== gtk-glextern: running =="
out=$("$work/gtk_round" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-glextern: FAILED =="; exit 1; }
echo "== gtk-glextern: OK =="
