#!/bin/sh
# run_rocks_window.sh — the `rocks-window` gate: the IB-style window (inspector tabs, library,
# Identity, Delete, New Form) in the real editor (test_rkwindow.xc), headless on AppKit.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-window: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-window: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkwindow.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/rkwindow" -q

out=$("$work/rkwindow" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-window: FAILED =="; exit 1; }
echo "== rocks-window: OK =="
