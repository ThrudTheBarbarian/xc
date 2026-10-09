#!/bin/sh
# run_rocks_menu.sh — the `rocks-menu` gate: making menus (a tree in the GEM shape), filling it, and
# its round-trip through the .rsc writer/reader.  Headless on AppKit.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-menu: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-menu: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkmenu.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/rkmenu" -q

out=$("$work/rkmenu" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-menu: FAILED =="; exit 1; }
echo "== rocks-menu: OK =="
