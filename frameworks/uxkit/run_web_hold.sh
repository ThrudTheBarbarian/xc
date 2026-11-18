#!/bin/sh
# run_web_hold.sh — the `web-hold` gate: a long press (UXView.holdDelay / mouseHeld) timed by
# trackDragStepWithin on the SAB ring in a worker_thread, the presses scripted from the parent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-hold: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-hold: building test_web_hold for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_hold" "$here/test_web_hold.xc" -q 2>/dev/null

echo "== web-hold: running (worker blocks, parent scripts the presses) =="
out=$(node "$here/run_web_hold.mjs" "$work/test_web_hold.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-hold: FAILED =="; exit 1; }
echo "== web-hold: OK =="
