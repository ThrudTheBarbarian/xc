#!/bin/sh
# The neutral springs & struts solver (UXView.resizeSubviews), exercised headless.  The same mask
# that drives AppKit's native NSView autoresizing drives the neutral layout the other backends use;
# this checks every mask lays out correctly.  macOS-only (builds the ObjC shim); the math is neutral.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-springs: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== springs: building the ObjC shim + the test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_springs.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_springs" -q 2>/dev/null

echo "== springs: running =="
"$work/test_springs"
