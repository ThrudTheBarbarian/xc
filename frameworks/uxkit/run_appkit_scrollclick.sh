#!/bin/sh
# run_appkit_scrollclick.sh -- the `appkit-scrollclick` gate: a click inside a scrolled NSScrollView lands
# on what shows there, not where it would be unscrolled.  Real NSEvents, posted.  Opens a live window
# for under a second.  macOS only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-scrollclick: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_appkit_scrollclick.xc" -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_scrollclick" -q
out=$(timeout 30 "$work/test_appkit_scrollclick") || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-scrollclick: FAILED =="; exit 1; }
echo "== appkit-scrollclick: OK =="
