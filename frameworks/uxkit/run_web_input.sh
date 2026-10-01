#!/bin/sh
# make web-input -- hover, drag, the secondary button and the wheel decoded and routed on the web
# backend, through the driver's own ring decoder and the toolkit's dispatch.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-input: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-input: building test_web_input for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_input" "$here/test_web_input.xc" -q 2>/dev/null

echo "== web-input: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_input.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-input: FAILED =="; exit 1; }
echo "== web-input: OK =="
