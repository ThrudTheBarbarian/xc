#!/bin/sh
# run_drawn_rowdrag.sh -- rows dragged out of tables and outlines as the toolkit draws them (the web,
# GEM), on AppKit with the pointer scripted.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== drawn-rowdrag: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== drawn-rowdrag: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_drawn_rowdrag.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_drawn_rowdrag" -q

echo "== drawn-rowdrag: running =="
got=$(timeout 15 "$work/test_drawn_rowdrag" 2>/dev/null) || true
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== drawn-rowdrag: FAIL =="; exit 1; }
echo "== drawn-rowdrag: OK =="
