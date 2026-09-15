#!/bin/sh
# make mac-chrome — the AppKit window chrome the driver used to leave empty: subtitle + the modified
# dot.  Asserts by reading the NSWindow back.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-chrome: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-chrome: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_mac_chrome.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_mac_chrome" -q 2>/dev/null
got=$("$work/test_mac_chrome" 2>&1)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: AppKit window chrome$'; then
    echo "== mac-chrome: PASS =="
else
    echo "== mac-chrome: FAIL =="; exit 1
fi
