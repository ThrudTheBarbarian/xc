#!/bin/sh
# run_appkit_textview.sh -- UXTextView on AppKit: the model, then the native NSTextView (content as
# attributed runs, the selection, styles, alignment, typing, emoji, undo and redo).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-textview: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-textview: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_textview.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_textview" -q

echo "== appkit-textview: running =="
got=$(timeout 15 "$work/test_appkit_textview" 2>/dev/null) || true
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== appkit-textview: FAIL =="; exit 1; }
echo "== appkit-textview: OK =="
