#!/bin/sh
# run_rocks.sh — build and run Rocks (the XC/UXKit rewrite).
#
# Rocks is an ordinary UXKit client: the only platform-aware line is the driver
# it constructs, so this script differs from a Win32/GTK/GEM one only in the
# shim it links.  `--build-only` compiles and stops, which is what CI wants and
# what a headless session can check.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks: skipped (AppKit build is macOS-only) =="; exit 0 ;; esac

# A persistent build dir, not mktemp: launching the editor should not rebuild
# a toolkit that has not changed.  Each artifact is rebuilt only when something
# it depends on is newer -- the shim on libUXAppKit.m, Rocks on any .xc in
# either tree.  `clean` or a removed build/ forces the lot.
work="$here/build"
mkdir -p "$work"
newest() { ls -t "$@" 2>/dev/null | head -1; }

SHIM="$work/libUXAppKit.dylib"
if [ ! -f "$SHIM" ] || [ "$ux/libUXAppKit.m" -nt "$SHIM" ]; then
  echo "== rocks: building the AppKit shim =="
  cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
     -install_name "$SHIM" "$ux/libUXAppKit.m" -framework Cocoa -o "$SHIM"
fi

NEWEST_SRC=$(newest "$here"/xc/*.xc "$ux"/*.xc)
if [ ! -f "$work/rocks" ] || [ "$NEWEST_SRC" -nt "$work/rocks" ] || [ "$SHIM" -nt "$work/rocks" ]; then
  echo "== rocks: building Rocks ($(basename "$NEWEST_SRC") changed) =="
  "$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" \
      -Xlinker "$SHIM" -framework Cocoa -o "$work/rocks" -q
else
  echo "== rocks: up to date =="
fi

case "${1:-}" in
  --build-only) echo "== rocks: BUILD OK ==" ; exit 0 ;;
esac

echo "== rocks: launching — close the window to exit =="
"$work/rocks"
echo "== rocks: done =="
