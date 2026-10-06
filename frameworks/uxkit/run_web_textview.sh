#!/bin/sh
# run_web_textview.sh -- the `web-textview` gate: UXTextView in a REAL browser's worker run loop
# (headless Chrome, cross-origin isolated).  Its editor is a contenteditable on the page;
# tools/web_textview.html types into it, selects, and presses the undo key, and checks what the app
# did to it.  Needs a compiler whose wasm32 loader has xccRequest (XCC_WORKER, default the in-tree
# bin/osx/xcc-xc); skips cleanly without one or without Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
# The in-tree compilers find their OWN support tree (loader, libraries) only through XCC_HOME until
# compiler 593: run from here they would otherwise fall back to the installed one.
case "$xcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-textview: skipped (no Chrome) =="; exit 0; }
[ -x "$xcc" ] || { echo "== web-textview: skipped (no compiler at $xcc) =="; exit 0; }
work=$(mktemp -d)
echo "== web-textview: building test_web_textview for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_textview" "$here/test_web_textview.xc" -q 2>/dev/null
grep -q xccPost "$work/test_web_textview.js" || { echo "== web-textview: skipped (this compiler's loader has no xccPost) =="; rm -rf "$work"; exit 0; }
cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_textview.html" "$work/"
port=8971
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1; rm -rf "$work" 2>/dev/null' EXIT
sleep 1
echo "== web-textview: headless Chrome =="
( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_textview.html?v=$$" >/dev/null 2>&1 & )
for i in $(seq 1 40); do [ -f "$work/result.txt" ] && break; sleep 1; done
out=$(cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page")
echo "$out"
echo "$out" | grep -q "^PAGE-FAIL" && { echo "== web-textview: FAILED =="; exit 1; }
echo "$out" | grep -q "^PASS" || { echo "== web-textview: FAILED =="; exit 1; }
echo "== web-textview: OK =="
