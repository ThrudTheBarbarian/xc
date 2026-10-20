#!/bin/sh
# make mac-icon -- the application icon on AppKit (UXApplication.setIcon / setIconPixels): the Dock
# tile, read back from NSApp -- the right size, the right way round, both pixel layouts.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/tools/mac_run.sh" # ux_mac_run: here, or on UX_MAC_GUI_HOST
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-icon: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-icon: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_mac_icon.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_mac_icon" -q 2>/dev/null
echo "== mac-icon: running (headless; the icon read back from NSApp) =="
out=$(ux_mac_run "$work/test_mac_icon")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== mac-icon: FAIL =="; exit 1; }
echo "== mac-icon: PASS =="
