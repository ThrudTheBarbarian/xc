#!/bin/sh
# make mac-dash — the DASH rendered for real on AppKit, checked as pixels.
#
# The seam could stroke a path natively but could not break the line, and a map's border is a dash at a
# phase that changes every frame.  This draws two subpaths in one stroke call and reads both back: a
# phase that restarts at the move makes them identical, a phase that carries on cannot, and the two
# rules disagree at every sample.  It also prints the run lengths of a pattern shorter than the stroke
# is wide, which is the case where a dasher may quietly stop dashing.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-dash: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-dash: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_mac_dash.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_mac_dash" -q 2>/dev/null
echo "== mac-dash: running (headless; one forced paint, pixels read back) =="
out=$("$work/test_mac_dash")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== mac-dash: FAIL =="; exit 1; }
echo "== mac-dash: PASS =="
