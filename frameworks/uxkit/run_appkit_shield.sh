#!/bin/sh
# The INPUT SHIELD, against a real click on a real native button.  The mirror of
# appkit-interactive: that gate asserts a click FIRES the button; this one puts a
# UXShieldView over the same button and asserts the click is intercepted instead
# -- the shield hears it, the button does not fire, and the coordinates arrive in
# the content view's space.  A real injected NSEvent, because the whole question
# is what AppKit does with the press.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-shield: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-shield: compiling the ObjC shim + the shield test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_shield.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_shield" -q 2>/dev/null

echo "== appkit-shield: running [NSApp run] + a click on a shielded button =="
got=$(timeout 20 "$work/test_appkit_shield" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-shield: PASS — a design surface intercepts clicks on live controls =="
else
    echo "== appkit-shield: FAIL =="
    exit 1
fi
