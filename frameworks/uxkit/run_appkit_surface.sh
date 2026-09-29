#!/bin/sh
# The self-painting surface, over a GL surface, on AppKit.  Two shapes, both required:
#   live     a real window: the surface is realised as a native subview ABOVE the GL surface,
#            and its ink is in the window's picture -- hiding the view takes the ink back out,
#            so the marks really are the view's and not the map's fallback.
#   headless no window, hence no surface: the view is painted inline through drawRect, the same
#            decline every backend without surfaces takes, and the shape CI runs.
# macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-surface: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-surface: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_surface.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit_surface" -q 2>/dev/null

for mode in headless live; do
  echo "== appkit-surface: $mode =="
  if [ "$mode" = headless ]; then
    out=$(UX_GL_HEADLESS=1 "$work/demo_appkit_surface")
  else
    out=$(timeout 30 "$work/demo_appkit_surface")
  fi
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-surface: FAIL ($mode) =="; exit 1; }
done
echo "== appkit-surface: OK =="
