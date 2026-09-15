#!/bin/sh
# The AppKit payoff: the REAL neutral UXKit layer (UXWindow + UXView + UXViewTree + UXButton, unchanged)
# running NATIVE on macOS via UXAppKitDriver — the third backend, sibling of the GEM and Win32 ones.
#
# Paint flows AppKit -> the neutral seam -> app code (drawRect: -> the content callback -> treeDraw
# -> ux_userdraw -> Canvas.drawRect, via UXCocoaGraphics/NSGraphicsContext).  A click routes through
# the SAME tree hit-test the GEM/Win32 backends use.  Headless-deterministic: forces one paint
# (cacheDisplayInRect), reads pixels back to prove it landed, injects two clicks, checks §10 returns
# to zero.  macOS-only (needs Cocoa); no window is shown.
#
#   xcc -A arm64 + the ObjC shim (libUXAppKit.m) -> a native binary.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit: compiling the ObjC shim + the REAL neutral layer for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_real.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_real" -q 2>/dev/null

echo "== appkit: running native (offscreen paint, no window shown) =="
got=$("$work/test_appkit_real" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit: PASS — the neutral UXKit layer runs native on a third backend =="
else
    echo "== appkit: FAIL =="
    exit 1
fi
