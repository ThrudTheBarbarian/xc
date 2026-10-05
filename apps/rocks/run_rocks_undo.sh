#!/bin/sh
# run_rocks_undo.sh — the `rocks-undo` gate: undo and redo of a drag, typing, a toggle and New
# Layout in the real editor (test_rkundo.xc), headless on AppKit.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-undo: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-undo: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkundo.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/rkundo" -q

out=$("$work/rkundo" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-undo: FAILED =="; exit 1; }
echo "== rocks-undo: OK =="
