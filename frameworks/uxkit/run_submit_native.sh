#!/bin/sh
# The AppKit half of the field-submit seam: a field's own end-of-editing, with the movement the
# text system names.  A Return submits; a Tab (and the rest) must not, or a panel would fire its
# command line every time the user tabbed away.  macOS-only; capture mode, no window shown.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== submit-native: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== submit-native: compiling the ObjC shim + the field form for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_submit_native.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_submit_native" -q 2>/dev/null

echo "== submit-native: running native (capture mode, no window shown) =="
got=$(timeout 20 "$work/test_submit_native" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== submit-native: PASS — only a Return ends editing into a submit =="
else
    echo "== submit-native: FAIL =="
    exit 1
fi
