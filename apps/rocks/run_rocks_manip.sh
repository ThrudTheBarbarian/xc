#!/bin/sh
# run_rocks_manip.sh — the `rocks-manip` gate: the canvas is a DESIGN surface.
# Order and routing (see test_rkmanip.xc), which unit tests cannot see.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-manip: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-manip: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkmanip.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/t" -q

out=$("$work/t" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-manip: FAILED =="; exit 1; }
echo "== rocks-manip: OK =="
