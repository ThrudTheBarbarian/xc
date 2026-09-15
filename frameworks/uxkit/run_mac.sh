#!/bin/sh
# make mac — the UXKit kitchen-sink on the AppKit backend: native widgets in a real macOS window.
# Resize it (the corner button anchors, the status line + table flex), click a row (multi-select),
# type in the field, toggle the checkbox/radio, use the Demo/Edit menu, pop an alert.  Foreground;
# close the window (or Demo > Quit) to exit.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== mac: building the ObjC shim + the kitchen-sink for arm64 =="
# The shim is a real dylib (install_name = where it lives for this run): xcc's -q linker references a
# -Xlinker input by name at load time, and a bare .o is an unloadable MH_OBJECT.  The dylib loads.
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/ks_mac.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/ks_mac" -q 2>/dev/null

echo "== mac: launching — close the window to exit =="
"$work/ks_mac"
echo "== mac: done =="
