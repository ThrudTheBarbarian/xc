#!/bin/sh
# The frame-time HUD over the real run loop: does it sample the live clock (min/prev/max/fps)?
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-hud: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-hud: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_hud.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit_hud" -q 2>/dev/null
out=$(timeout 30 "$work/demo_appkit_hud")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-hud: FAIL =="; exit 1; }
echo "== appkit-hud: OK =="
