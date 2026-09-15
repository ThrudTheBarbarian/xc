#!/bin/sh
# run_rkcanvas.sh — the `rocks-canvas` gate: Rocks' builder and controller agree
# on every wiring name, headless.  Guards the nib bootstrap (see the test).
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-canvas: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-canvas: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkcanvas.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/rkcanvas" -q

out=$("$work/rkcanvas" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-canvas: FAILED =="; exit 1; }
echo "== rocks-canvas: OK =="
