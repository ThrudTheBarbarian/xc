#!/bin/sh
# make mac-sound -- sound on AppKit (UXSound.play through NSSound): starts, overlaps and
# finishes.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/tools/mac_run.sh" # ux_mac_run: here, or on UX_MAC_GUI_HOST
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-sound: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-sound: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_mac_sound.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_mac_sound" -q 2>/dev/null
echo "== mac-sound: running (headless) =="
out=$(ux_mac_run "$work/test_mac_sound")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== mac-sound: FAIL =="; exit 1; }
echo "== mac-sound: PASS =="
