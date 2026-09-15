#!/bin/sh
# The neutral multi-selection model, exercised headless on the AppKit backend.  Drives UXTableView's
# selection ops directly (replace / ctrl-toggle / shift-extend / adopt-native) and reads the set back
# — no window shown.  macOS-only (builds the ObjC shim); the model itself is backend-neutral.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-multisel: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-multisel: building the ObjC shim + the test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_multisel.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_multisel" -q 2>/dev/null

echo "== appkit-multisel: running =="
"$work/test_appkit_multisel"
