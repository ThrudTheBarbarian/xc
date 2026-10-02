#!/bin/sh
# run_appkit_navtree.sh -- UXNavigationController in a real window tree on AppKit (headless): only
# the top form shows, after push, pop and popToRoot (a popped form used to stay visible).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-navtree: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-navtree: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_navtree.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_navtree" -q 2>/dev/null
echo "== appkit-navtree: running =="
out=$("$work/test_navtree")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-navtree: FAIL =="; exit 1; }
echo "== appkit-navtree: PASS =="
