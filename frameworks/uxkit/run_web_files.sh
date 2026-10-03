#!/bin/sh
# run_web_files.sh -- the `web-files` gate: open and save on the web, in headless Chrome's worker
# run loop (served cross-origin isolated).  A save is the browser's download; an open is the page's
# dialog and the real file picker, the file's bytes pulled into the worker with xccRequest.  Needs
# the worker hooks (XCC_WORKER, default the in-tree compiler); skips cleanly without one or Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
# The in-tree compilers find their OWN support tree (loader, libraries) only through XCC_HOME until
# compiler 593: run from here they would otherwise fall back to the installed one.
case "$xcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-files: skipped (no Chrome) =="; exit 0; }
[ -x "$xcc" ] || { echo "== web-files: skipped (no compiler at $xcc) =="; exit 0; }
work=$(mktemp -d)
echo "== web-files: building test_web_files for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_files" "$here/test_web_files.xc" -q 2>/dev/null
grep -q xccPost "$work/test_web_files.js" || { echo "== web-files: skipped (this compiler's loader has no xccPost) =="; rm -rf "$work"; exit 0; }
cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_files.html" "$work/"
port=8962
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1; rm -rf "$work" 2>/dev/null' EXIT
sleep 1
echo "== web-files: headless Chrome =="
( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_files.html?v=$$" >/dev/null 2>&1 & )
for i in $(seq 1 40); do [ -f "$work/result.txt" ] && break; sleep 1; done
out=$(cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page")
echo "$out"
echo "$out" | grep -q "^PAGE-FAIL" && { echo "== web-files: FAILED =="; exit 1; }
echo "$out" | grep -q "^PASS" || { echo "== web-files: FAILED =="; exit 1; }
echo "== web-files: OK =="
