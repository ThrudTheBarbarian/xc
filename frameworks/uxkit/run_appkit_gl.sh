#!/bin/sh
# The AppKit GL seam.  Two shapes, both required:
#   live     — a real window: does makeGL bind a context, does the swap run, do both go away
#              clean, and does the process exit 0 (a GL client that leaks its context dies on
#              the way out).
#   headless — no window, which is how CI runs: there is no surface, so the view must still be
#              painted by drawRect through the same neutral path a no-GL backend uses.
# macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-gl: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-gl: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_gl.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit_gl" -q 2>/dev/null

for mode in headless live; do
  echo "== appkit-gl: $mode =="
  if [ "$mode" = headless ]; then
    out=$(UX_GL_HEADLESS=1 "$work/demo_appkit_gl")
  else
    out=$("$work/demo_appkit_gl")
  fi
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-gl: FAIL ($mode) =="; exit 1; }
done
echo "== appkit-gl: OK =="
