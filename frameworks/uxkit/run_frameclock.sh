#!/bin/sh
# The app's frame clock (UXApplication.everyTurn) on the neutral run loop.  Headless AppKit, so
# the driver answers setTurnHook with false and the loop paces itself: ms becomes the deadline it
# hands nextEvent, and fn runs once per turn after that turn's draws.  Asserts that turns arrive,
# that they come at the cadence asked for (not the toolkit's default poll), that a click queued
# between turns is still dispatched, and that the caller is told which clock it got.
#
#   xcc -A arm64 + the ObjC shim (libUXAppKit.m) -> a native binary.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== frameclock: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== frameclock: compiling the ObjC shim + the frame clock for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_frameclock.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_frameclock" -q 2>/dev/null

echo "== frameclock: running native under UXApplication.run() =="
got=$(timeout 20 "$work/test_frameclock" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== frameclock: PASS — the neutral loop turns the clock the app asked for =="
else
    echo "== frameclock: FAIL =="
    exit 1
fi
