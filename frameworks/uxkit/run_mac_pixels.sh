#!/bin/sh
# make mac-pixels -- a bitmap region drawn in a drawRect (drawPixels) on AppKit, checked as pixels:
# the right way up, the right region, scaled, alpha honoured, and both byte layouts read correctly.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-pixels: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-pixels: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_mac_pixels.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_mac_pixels" -q 2>/dev/null
echo "== mac-pixels: running (headless; one forced paint, pixels read back) =="
out=$("$work/test_mac_pixels")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== mac-pixels: FAIL =="; exit 1; }
echo "== mac-pixels: PASS =="
