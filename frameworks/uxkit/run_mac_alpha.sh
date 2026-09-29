#!/bin/sh
# make mac-alpha — the RGBA family (and the clear) blended for real on AppKit, checked as pixels.
#
# The 2-D path was opaque: every primitive took a pen index or an RGB triple and the AppKit backend
# built every NSColor with alpha:1.0, so a layer that wanted a coastline at 0.92 or a border glow at
# 0.12 could not draw it.  This renders three greys (alpha 255, 128, 64) and two translucent coloured
# shapes over white and reads the pixels back, so the blend is measured and not assumed.  Without the
# change the alpha-128 rectangle is solid black and every check below fails.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-alpha: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-alpha: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_mac_alpha.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_mac_alpha" -q 2>/dev/null
echo "== mac-alpha: running (headless; one forced paint, pixels read back) =="
out=$("$work/test_mac_alpha")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== mac-alpha: FAIL =="; exit 1; }
echo "== mac-alpha: PASS =="
