#!/bin/sh
# AppKit input as the toolkit hears it: modifier keys on presses and keys, the middle button, key
# releases and the keys with no character (test_appkit_input.xc), headless.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/tools/mac_run.sh" # ux_mac_run: here, or on UX_MAC_GUI_HOST
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-input: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-input: compiling the ObjC shim + the input test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_input.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_input" -q

echo "== appkit-input: AppKit events into the toolkit =="
got=$(ux_mac_run -t 15 "$work/test_appkit_input" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-input: PASS =="
else
    echo "== appkit-input: FAIL =="
    exit 1
fi
