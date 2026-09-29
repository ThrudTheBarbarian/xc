#!/bin/sh
# The INTERACTIVE AppKit demo — the neutral UXKit toolkit as a real macOS app.  Shows a window: click
# the Alert/Quit buttons, type in the text field, use the Demo/Edit menu bar, pop an NSAlert, close
# the window to exit.  Nothing in the app is AppKit-aware except the driver + setInteractive(true).
# macOS-only.  Closes itself after a moment; --stay keeps it up to poke at.
set -e
# The demo closes ITSELF after a moment (see demo_autoquit.xc), so a run cannot camp
# on the screen and hold the keyboard focus.  --stay keeps it up until you close it;
# --auto-quit [ms] keeps it self-closing with a different delay.
case "${1:-}" in
  --stay)      UX_AUTOQUIT=0; export UX_AUTOQUIT ;;
  --auto-quit) UX_AUTOQUIT=${2:-1500}; export UX_AUTOQUIT ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-demo: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-demo: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit" -q 2>/dev/null

echo "== appkit-demo: launching (self-closing; --stay to keep it up) =="
"$work/demo_appkit"
echo "== appkit-demo: done =="
