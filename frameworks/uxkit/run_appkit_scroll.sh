#!/bin/sh
# The AppKit native-scrolling demo — the neutral UXKit toolkit inside a real NSScrollView.  Shows a
# window whose document is far taller than the frame; scroll it with the trackpad, wheel, or the
# native scrollbar.  No scroll code in the app: it just reports its content size and NSScrollView
# owns the offset (elastic overscroll, momentum, overlay scrollers).  macOS-only.  Foreground.
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
case "$(uname)" in Darwin) ;; *) echo "== appkit-scroll: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-scroll: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_scroll.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/demo_appkit_scroll" -q 2>/dev/null

echo "== appkit-scroll: launching — scroll the window, then close it to exit =="
"$work/demo_appkit_scroll"
echo "== appkit-scroll: done =="
