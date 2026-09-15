#!/bin/sh
# run_web_alert.sh — the `web-alert` milestone gate (design doc §5):
# alertRun blocking on the SAB ring in a worker_thread, the parent playing
# the page's role and answering button 2 through a type-7 ring event.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-alert: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-alert: building test_web_alert for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_alert" "$here/test_web_alert.xc" -q 2>/dev/null

echo "== web-alert: running (worker blocks, parent pushes the click) =="
out=$(node "$here/run_web_alert.mjs" "$work/test_web_alert.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-alert: FAILED =="; exit 1; }
echo "== web-alert: OK =="
