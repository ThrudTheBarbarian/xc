#!/bin/sh
# run_web_worker.sh -- the `web-worker` gate: UXKit in a REAL browser's worker run loop (headless
# Chrome, cross-origin isolated).  The page builds the DOM menu bar and the DOM alert from what the
# worker posts (the loader's xccPost, compiler 587), answers the alert through the ring, and a pick
# in the menu bar fires an item in the running app.  Needs a compiler whose wasm32 loader has
# xccPost (XCC_WORKER, default the in-tree bin/osx/xcc); skips cleanly without one or without Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc"}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-worker: skipped (no Chrome) =="; exit 0; }
[ -x "$xcc" ] || { echo "== web-worker: skipped (no compiler at $xcc) =="; exit 0; }
work=$(mktemp -d)
echo "== web-worker: building test_web_worker for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_worker" "$here/test_web_worker.xc" -q 2>/dev/null
grep -q xccPost "$work/test_web_worker.js" || { echo "== web-worker: skipped (this compiler's loader has no xccPost) =="; rm -rf "$work"; exit 0; }
cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_worker.html" "$work/"
port=8963
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1; rm -rf "$work" 2>/dev/null' EXIT
sleep 1
echo "== web-worker: headless Chrome =="
( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_worker.html?v=$$" >/dev/null 2>&1 & )
for i in $(seq 1 40); do [ -f "$work/result.txt" ] && break; sleep 1; done
out=$(cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page")
echo "$out"
echo "$out" | grep -q "^PAGE-FAIL" && { echo "== web-worker: FAILED =="; exit 1; }
echo "$out" | grep -q "^PASS" || { echo "== web-worker: FAILED =="; exit 1; }
echo "== web-worker: OK =="
