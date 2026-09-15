#!/bin/sh
# Live text editing native on AppKit (sibling of run_win32_field.sh).  A form with a text field
# driven through the neutral run loop: a posted click focuses the field, posted key-downs travel
# driver.nextEvent -> dispatchKey -> UXTextField.keyDown -> driver.editText.  "Hi", Backspace, "o"
# -> "Ho".  macOS-only; no window shown.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-field: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-field: compiling the ObjC shim + the field form for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_field.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_field" -q 2>/dev/null

echo "== appkit-field: running native under UXApplication.run() =="
got=$(timeout 20 "$work/test_appkit_field" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-field: PASS — live text editing on the third backend =="
else
    echo "== appkit-field: FAIL =="
    exit 1
fi
