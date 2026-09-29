#!/bin/sh
# A native control inside a scroll view, on AppKit.  The realizeTree re-parent pass must move the
# control into the scroll's DOCUMENT view so it scrolls and clips with the scroll; the gate counts
# the move.  Headless there is no native control, so nothing moves.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-scrollpanel: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-scrollpanel: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_scrollpanel.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit_scrollpanel" -q 2>/dev/null
for mode in headless live; do
  echo "== appkit-scrollpanel: $mode =="
  if [ "$mode" = headless ]; then out=$(UX_GL_HEADLESS=1 "$work/demo_appkit_scrollpanel")
  else out=$(timeout 30 "$work/demo_appkit_scrollpanel"); fi
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-scrollpanel: FAIL ($mode) =="; exit 1; }
done
echo "== appkit-scrollpanel: OK =="
