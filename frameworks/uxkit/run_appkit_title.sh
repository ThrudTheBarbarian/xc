#!/bin/sh
# run_appkit_title.sh -- a title changed after a control is on screen reaches the native control:
# a button's, a check box's and a label's.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-title: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-title: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_title.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_title" -q

echo "== appkit-title: running =="
got=$(timeout 15 "$work/test_appkit_title" 2>/dev/null) || true
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== appkit-title: FAIL =="; exit 1; }
echo "== appkit-title: OK =="
