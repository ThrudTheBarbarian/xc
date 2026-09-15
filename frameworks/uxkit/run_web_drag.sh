#!/bin/sh
# run_web_drag.sh — the `web-drag` milestone gate (design doc §5):
# trackDragStep blocking on the SAB ring in a worker_thread, a scripted drag
# pushed from the parent, the slider following it step by step.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-drag: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-drag: building test_web_drag for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_drag" "$here/test_web_drag.xc" -q 2>/dev/null

echo "== web-drag: running (worker blocks, parent pushes the click) =="
out=$(node "$here/run_web_drag.mjs" "$work/test_web_drag.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-drag: FAILED =="; exit 1; }
echo "== web-drag: OK =="
