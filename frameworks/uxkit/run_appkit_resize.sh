#!/bin/sh
# The AppKit live-resize demo — the neutral toolkit tracks the native window frame.  Drag the window
# edge: the custom view reflows to fill the new size, a native button stays anchored to the
# bottom-right corner, and a label shows the live size — all via the neutral windowDidResize hook.
# Nothing in the app is AppKit-aware except the driver.  macOS-only.  Foreground.
set -e
# --auto-quit [ms]: close the demo by itself after a delay, so a sweep can run it
# unattended.  It exits through the SAME path the close box takes, so it still
# prints whatever it prints -- a killed demo reports nothing and is
# indistinguishable from one that crashed.  An XC main() takes no argv, so the
# option lives here and reaches the binary as UX_AUTOQUIT.
case "${1:-}" in
  --auto-quit) UX_AUTOQUIT=${2:-1500}; export UX_AUTOQUIT ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-resize: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-resize: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_resize.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/demo_appkit_resize" -q 2>/dev/null

echo "== appkit-resize: launching — drag the window frame, then close it to exit =="
"$work/demo_appkit_resize"
echo "== appkit-resize: done =="
