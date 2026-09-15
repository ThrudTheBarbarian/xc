#!/bin/sh
# The per-backend memory gate for AppKit (doc/XTG-MULTIPLATFORM.md §10), sibling of
# run_win32_memgate.sh.  Opens/closes N windows (each a real form: content view + button + field) in
# a loop and asserts the driver's native-object counter returns to baseline — no leaked NSWindow/
# NSView.  The malloc-address heap oracle is printed but NOT asserted here: Cocoa churns its own
# allocator caches, so it is not a valid leak detector for this backend (see the test's header).
# macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-memgate: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-memgate: compiling the ObjC shim + the §10 gate for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_memgate.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_memgate" -q 2>/dev/null

echo "== appkit-memgate: running the create/destroy loop native =="
got=$(timeout 30 "$work/test_appkit_memgate" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-memgate: PASS — no native window leaked over the cycles =="
else
    echo "== appkit-memgate: FAIL =="
    exit 1
fi
