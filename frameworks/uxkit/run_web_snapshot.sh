#!/bin/sh
# run_web_snapshot.sh -- the `web-snapshot` gate: UXWindow.snapshot on the web, in headless Chrome's
# worker run loop (served cross-origin isolated) with WebGL2 in the worker: the GL view, the 2-D
# views over it and the drawn button, whole or a region.  Needs the worker hooks (XCC_WORKER, default
# the in-tree compiler); skips cleanly without one or Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
# The in-tree compilers find their OWN support tree (loader, libraries) only through XCC_HOME until
# compiler 593: run from here they would otherwise fall back to the installed one.
case "$xcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-snapshot: skipped (no Chrome) =="; exit 0; }
[ -x "$xcc" ] || { echo "== web-snapshot: skipped (no compiler at $xcc) =="; exit 0; }
work=$(mktemp -d)
echo "== web-snapshot: building test_snapshot for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_snapshot" -D SNAP_WEB "$here/test_snapshot.xc" -q 2>/dev/null
grep -q xccPost "$work/test_snapshot.js" || { echo "== web-snapshot: skipped (this compiler's loader has no xccPost) =="; rm -rf "$work"; exit 0; }
cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_snapshot.html" "$work/"
port=8968
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1; rm -rf "$work" 2>/dev/null' EXIT
sleep 1
echo "== web-snapshot: headless Chrome =="
( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_snapshot.html?v=$$" >/dev/null 2>&1 & )
for i in $(seq 1 40); do [ -f "$work/result.txt" ] && break; sleep 1; done
out=$(cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page")
echo "$out"
echo "$out" | grep -q "^PAGE-FAIL" && { echo "== web-snapshot: FAILED =="; exit 1; }
echo "$out" | grep -q "^PASS" || { echo "== web-snapshot: FAILED =="; exit 1; }
echo "== web-snapshot: OK =="
