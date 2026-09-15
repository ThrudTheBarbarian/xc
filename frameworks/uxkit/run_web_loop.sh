#!/bin/sh
# run_web_loop.sh — the `web-loop` milestone gate (design doc §5):
# UXApplication.run() blocking on the SAB ring in a worker_thread, a click
# pushed from the parent, the bound action firing, run() returning.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-loop: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-loop: building test_web_loop for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_loop" "$here/test_web_loop.xc" -q 2>/dev/null

echo "== web-loop: running (worker blocks, parent pushes the click) =="
out=$(node "$here/run_web_loop.mjs" "$work/test_web_loop.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-loop: FAILED =="; exit 1; }
echo "== web-loop: OK =="
