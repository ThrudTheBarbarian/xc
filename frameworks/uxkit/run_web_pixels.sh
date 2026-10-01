#!/bin/sh
# make web-pixels -- a bitmap region drawn in a drawRect (drawPixels) on the web backend, read back through
# the node rig: orientation, region, scale, alpha and both byte layouts.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-pixels: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-pixels: building test_web_pixels for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_pixels" "$here/test_web_pixels.xc" -q 2>/dev/null

echo "== web-pixels: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_pixels.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-pixels: FAILED =="; exit 1; }
echo "== web-pixels: OK =="
