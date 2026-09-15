#!/bin/sh
# The neutral RUN LOOP native on AppKit (sibling of run_win32_loop.sh).  Runs the app under
# UXApplication.run() — the SAME loop the GEM/Win32 apps use — pumping the REAL NSApplication event
# queue: a synthetic mouse-down posted with NSEvent travels driver.nextEvent (a run-loop pump +
# nextEventMatchingMask -> decode) -> UXApplication.dispatchEvent -> UXView.mouseDown, and a posted
# quit ends the loop.  macOS-only; no window is shown.
#
#   xcc -A arm64 + the ObjC shim (libUXAppKit.m) -> a native binary.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-loop: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-loop: compiling the ObjC shim + the neutral run loop for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_loop.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_loop" -q 2>/dev/null

echo "== appkit-loop: running native under UXApplication.run() =="
got=$(timeout 20 "$work/test_appkit_loop" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-loop: PASS — the neutral run loop pumps AppKit events =="
else
    echo "== appkit-loop: FAIL =="
    exit 1
fi
