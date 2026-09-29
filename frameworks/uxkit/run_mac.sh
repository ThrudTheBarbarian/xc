#!/bin/sh
# make mac — the UXKit kitchen-sink on the AppKit backend: native widgets in a real macOS window.
# Resize it (the corner button anchors, the status line + table flex), click a row (multi-select),
# type in the field, toggle the checkbox/radio, use the Demo/Edit menu, pop an alert.  It closes
# itself after a moment; --stay keeps it up to poke at.  macOS-only.
set -e
# The kitchen sink closes ITSELF after a moment (see demo_autoquit.xc), so a run cannot
# camp on the screen and hold the keyboard focus.  --stay keeps it up to poke at;
# --auto-quit [ms] keeps it self-closing with a different delay.
case "${1:-}" in
  --stay)      UX_AUTOQUIT=0; export UX_AUTOQUIT ;;
  --auto-quit) UX_AUTOQUIT=${2:-1500}; export UX_AUTOQUIT ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== mac: building the ObjC shim + the kitchen-sink for arm64 =="
# The shim is a real dylib (install_name = where it lives for this run): xcc's -q linker references a
# -Xlinker input by name at load time, and a bare .o is an unloadable MH_OBJECT.  The dylib loads.
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/ks_mac.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/ks_mac" -q 2>/dev/null

echo "== mac: launching (self-closing; --stay to keep it up) =="
"$work/ks_mac"
echo "== mac: done =="
