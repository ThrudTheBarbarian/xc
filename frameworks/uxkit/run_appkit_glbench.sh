#!/bin/sh
# The GL frame harness (T0's instrument): a real window, a GL surface, and four timed
# configurations.  Checks the PLUMBING -- a context made, the sheet uploaded, the
# device ratio stated, one draw call per frame, four configurations timed, both frames
# dumped and both dumps non-blank -- and not the numbers, which are the map's, at the
# real camera.  Two dumps on purpose: the surface one holds the map and no text, the
# window one holds the text and no map, and each is CHECKED to hold what it claims.
# macOS-only.
#
# Point UX_GL_ATLAS at a PNG and the harness decodes it with the toolkit's own decoder
# and uploads it as the sheet -- the real atlas through the real path, no host shortcut.
# Left unset, the procedural sheet stands in.  The geometry still needs the client's
# camera; the sheet and the camera are separate inputs.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-glbench: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-glbench: building the ObjC shim + the harness for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/demo_gl.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_gl" -q 2>/dev/null

echo "== appkit-glbench: running (bounded loop; no window interaction needed) =="
out=$(timeout 120 "$work/demo_gl")
printf '%s\n' "$out"

fail=0
for want in 'glKind=' 'ratio ' 'still map only' 'still + text' 'moving map only' 'moving + text' 'frame dumped' 'window dumped' '^PASS'; do
  printf '%s\n' "$out" | grep -q "$want" || { echo "  missing: $want"; fail=1; }
done
[ "$fail" = 0 ] || { echo "== appkit-glbench: FAIL =="; exit 1; }
echo "== appkit-glbench: OK =="
