#!/bin/sh
# run_appkit_leak.sh -- AppKit's headless present path leaks nothing per frame: a 1280x832 window
# repainted 300 times, the process footprint compared (it was one whole frame, 4.26 MB, per frame).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-leak: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-leak: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_appkit_leak.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_leak" -q 2>/dev/null
echo "== appkit-leak: running (headless, 300 frames) =="
out=$("$work/test_appkit_leak")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-leak: FAIL =="; exit 1; }
echo "== appkit-leak: PASS =="
