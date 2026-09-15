#!/bin/sh
# Headless smoke test for the AppKit menu path: builds a neutral UXMenuBar and installs it via the
# driver (menuBuild -> NSMenu), asserting menu construction doesn't crash.  (Menu SELECTION is
# interactive — exercised in the demo, `make appkit-demo`.)  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-menu: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-menu: compiling the ObjC shim + the menu smoke test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_menu.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_menu" -q 2>/dev/null

echo "== appkit-menu: building an NSMenu from the neutral model =="
got=$(timeout 15 "$work/test_appkit_menu" 2>/dev/null)
printf '%s\n' "$got"

if printf '%s\n' "$got" | grep -q '^PASS'; then
    echo "== appkit-menu: PASS — the neutral menu model builds an NSMenu =="
else
    echo "== appkit-menu: FAIL =="
    exit 1
fi
