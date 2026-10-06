#!/bin/sh
# run_rocks_gtk.sh — the `rocks-gtk` gate: Rocks on GTK 4, built on the Mac against the host's GTK
# (-D RK_GTK, see RKDriver.xc), so the Linux editor's UI is tried without the Linux host.  Opens
# the main window on its sample and checks it was built and wired.  Skips without GTK 4.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== rocks-gtk: skipped (no gtk4) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-gtk: building the shim + Rocks =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$ux/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib" 2>/dev/null
"$xcc" -A arm64 -D RK_GTK -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/rocks" -q
echo "== rocks-gtk: running =="
out=$(timeout 8 "$work/rocks" 2>&1 | grep -v Warning) || true  # it runs on; the timeout ends it
echo "$out" | grep -E "^(PASS|FAIL|SKIP)" | head -1
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "$out" | tail -10; echo "== rocks-gtk: FAILED =="; exit 1; }
echo "== rocks-gtk: OK — Rocks runs on GTK =="
