#!/bin/sh
# run_rocks_connect.sh — the `rocks-connect` gate: outlets and actions drawn in Rocks per layout
# theme, then bound per layout by UXNib (test_rkconnect.xc), headless on AppKit.  The controller's
# class is read from its source, and from a library built from it here.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-connect: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== rocks-connect: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$ux/libUXAppKit.m" \
   -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$ux" -I "$here/xc" --emit-lib "$here/xc/fixture_player.xc" -o "$work/libplayer.dylib" -q
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkconnect.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/rkconnect" -q

# an app folder the document is first saved into: its class must be read then
mkdir -p "$work/app"
printf 'class SavedHere : Object\n    {\n    outlet UXButton* go;\n    }\n' > "$work/app/SavedHere.xc"
out=$(RK_SRC="$here/xc/fixture_player.xc" RK_LIB="$work/libplayer.dylib" RK_APP="$work/app" "$work/rkconnect" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-connect: FAILED =="; exit 1; }
echo "== rocks-connect: OK =="
