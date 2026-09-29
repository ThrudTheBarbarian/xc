#!/bin/sh
# make mac-weight — a family at a numeric WEIGHT, blended for real on AppKit, checked as pixels.
#
# The map's labels are `600 10px ui-monospace, Menlo, monospace` in an rgba() colour: a family, a
# weight, a colour and an alpha, all four at once.  drawTextFont could name a family but only a bool
# `bold`; drawTextRGBA could carry a colour and an alpha but no family.  This renders the same string
# at weight 400 and 600 in one family over white and reads the ink back, so the weight is measured and
# not assumed — 600 is semibold, which `bold` cannot say.  Without the change both weights resolve to
# one face and the ink totals are equal, which is what the checks reject.  Skips cleanly off macOS.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-weight: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-weight: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_mac_weight.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_mac_weight" -q 2>/dev/null
echo "== mac-weight: running (headless; one forced paint, pixels read back) =="
out=$("$work/test_mac_weight")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== mac-weight: FAIL =="; exit 1; }
echo "== mac-weight: PASS =="
