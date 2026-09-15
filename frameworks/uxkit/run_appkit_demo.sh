#!/bin/sh
# The INTERACTIVE AppKit demo — the neutral UXKit toolkit as a real macOS app.  Shows a window: click
# the Alert/Quit buttons, type in the text field, use the Demo/Edit menu bar, pop an NSAlert, close
# the window to exit.  Nothing in the app is AppKit-aware except the driver + setInteractive(true).
# macOS-only.  Runs in the foreground; close the window (or Demo > Quit) to return.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-demo: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-demo: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/demo_appkit" -q 2>/dev/null

echo "== appkit-demo: launching — close the window to exit =="
"$work/demo_appkit"
echo "== appkit-demo: done =="
