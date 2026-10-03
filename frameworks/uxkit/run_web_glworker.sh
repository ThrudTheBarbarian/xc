#!/bin/sh
# run_web_glworker.sh -- the `web-glworker` gate: WebGL2 in the worker run loop, in headless Chrome
# (served cross-origin isolated): a GL view's OffscreenCanvas composited under the 2-D layer into the
# frame the worker posts, checked on the page's display canvas.  Then the same app on a plain page,
# where the GL is a DOM canvas under the 2-D one, checked in a screenshot.  Needs the worker hooks (XCC_WORKER,
# default the in-tree compiler); skips cleanly without one or Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
# The in-tree compilers find their OWN support tree (loader, libraries) only through XCC_HOME until
# compiler 593: run from here they would otherwise fall back to the installed one.
case "$xcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-glworker: skipped (no Chrome) =="; exit 0; }
[ -x "$xcc" ] || { echo "== web-glworker: skipped (no compiler at $xcc) =="; exit 0; }
work=$(mktemp -d)
echo "== web-glworker: building test_web_glworker for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_glworker" "$here/test_web_glworker.xc" -q 2>/dev/null
grep -q xccPost "$work/test_web_glworker.js" || { echo "== web-glworker: skipped (this compiler's loader has no xccPost) =="; rm -rf "$work"; exit 0; }
cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_glworker.html" "$work/"
port=8961
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1; rm -rf "$work" 2>/dev/null' EXIT
sleep 1
echo "== web-glworker: headless Chrome =="
( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_glworker.html?v=$$" >/dev/null 2>&1 & )
for i in $(seq 1 40); do [ -f "$work/result.txt" ] && break; sleep 1; done
out=$(cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page")
echo "$out"
echo "$out" | grep -q "^PAGE-FAIL" && { echo "== web-glworker: FAILED =="; exit 1; }
echo "$out" | grep -q "^PASS" || { echo "== web-glworker: FAILED =="; exit 1; }
echo "== web-glworker: the same app on a plain page (a screenshot) =="
cp "$here/tools/web_gldraw.html" "$work/"
timeout 60 "$CHROME" --headless=new --user-data-dir="$work/chrome3" --window-size=240,160 --hide-scrollbars --timeout=4000 \
    --screenshot="$work/page.png" "http://localhost:$port/web_gldraw.html" >/dev/null 2>&1 || true
px() { magick "$work/page.png" -format "%[fx:int(255*p{$1,$2}.r)],%[fx:int(255*p{$1,$2}.g)],%[fx:int(255*p{$1,$2}.b)]" info: 2>/dev/null; }
cleared=$(px 200 20); drawn=$(px 20 20); over=$(px 120 80)
echo "page: cleared $cleared drawn $drawn over $over"
near() { echo "$1" | awk -F, -v r=$2 -v g=$3 -v b=$4 '{ d=($1-r)^2+($2-g)^2+($3-b)^2; exit !(d < 400) }'; }
near "$cleared" 64 128 191 && near "$drawn" 32 191 64 && near "$over" 230 20 20 || { echo "== web-glworker: FAILED (the page leg) =="; exit 1; }
echo "== web-glworker: OK =="
