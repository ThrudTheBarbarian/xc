#!/bin/sh
# A click on the SECOND window routes to the second window's view, not the first (sibling of
# run_win32_winroute.sh).  The neutral dispatchEvent only asks the driver to resolve a point when the
# event carries no window handle — the headless posted-click path — so that is where the answer has to
# come from.  macOS-only; no window is shown.
#
#   xcc -A arm64 + the ObjC shim (libUXAppKit.m) -> a native binary.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-winroute: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-winroute: compiling the ObjC shim + the routing test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_winroute.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_winroute" -q 2>/dev/null

echo "== appkit-winroute: running native =="
got=$(timeout 20 "$work/test_appkit_winroute" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-winroute: PASS — multi-window clicks route by the event's own window =="
else
    echo "== appkit-winroute: FAIL =="
    exit 1
fi
