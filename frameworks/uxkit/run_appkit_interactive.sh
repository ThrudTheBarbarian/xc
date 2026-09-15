#!/bin/sh
# Automated test of the INTERACTIVE dispatch path: the real [NSApp run] stack with the content view
# forwarding events, driven by one injected click at a Quit button.  The click must travel AppKit ->
# mouseDown: -> the dispatch trampoline -> UXApplication.dispatchEvent -> the toolkit hit-test -> the
# button action -> app.stop() -> [NSApp run] returns.  If it quits, the chain works (and doesn't
# hang).  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-interactive: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-interactive: compiling the ObjC shim + the interactive dispatch test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_interactive.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_interactive" -q 2>/dev/null

echo "== appkit-interactive: running [NSApp run] + an injected click =="
got=$(timeout 20 "$work/test_appkit_interactive" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-interactive: PASS — a click drives the toolkit under [NSApp run] =="
else
    echo "== appkit-interactive: FAIL =="
    exit 1
fi
