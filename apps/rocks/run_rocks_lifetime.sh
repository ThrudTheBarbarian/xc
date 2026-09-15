#!/bin/sh
# run_rocks_lifetime.sh — the `rocks-lifetime` gate: the document outlives the
# editing of it.
#
# Rocks crashed after ~30 canvas clicks because a model object was freed while
# the resource still held it.  Every other gate clicked and passed: freed memory
# usually still LOOKS like a valid object, so a lifetime bug reads as working
# code right up until it segfaults.
#
# MallocScribble=1 is what makes this gate honest -- freed memory becomes 0x55..
# so the test catches the dangling pointer at the first read.  Without it this
# passes while broken, so it is set here rather than left to the caller.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-lifetime: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-lifetime: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rklifetime.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/t" -q

out=$(MallocScribble=1 "$work/t" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-lifetime: FAILED =="; exit 1; }
echo "== rocks-lifetime: OK =="
