#!/bin/sh
# run_web_real.sh — the web driver's bring-up gate (design doc §5, `web-real`).
# Compiles test_web_real.xc for wasm32 and runs it under Node with the recording
# canvas rig (ux_web_node.js) supplying the host imports.  Skips cleanly when
# node is absent, the same discipline as the Wine suite.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-real: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-real: building test_web_real for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_real" "$here/test_web_real.xc" -q 2>/dev/null

echo "== web-real: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_real.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-real: FAILED =="; exit 1; }
echo "== web-real: OK =="
