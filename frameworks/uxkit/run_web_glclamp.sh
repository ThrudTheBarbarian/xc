#!/bin/sh
# run_web_glclamp.sh -- the web GL view's canvas in real headless Chrome: one canvas per GL view
# however often the tree is realized, its pixel size clamped to the GPU's limit (lowered to 64 by the
# page) with the view's aspect, its CSS size the view's, and a resize followed.  Skips without Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-glclamp: skipped (no Chrome) =="; exit 0; }
work=$(mktemp -d)
echo "== web-glclamp: building test_web_glclamp for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_glclamp" "$here/test_web_glclamp.xc" -q 2>/dev/null
cp "$here/ux_web_browser.js" "$here/tools/web_glclamp.html" "$work/"
port=8937
pkill -f "http.server $port" 2>/dev/null || true
( cd "$work" && exec python3 -m http.server $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$work"' EXIT
sleep 1
echo "== web-glclamp: headless Chrome =="
title=$("$CHROME" --headless=new --use-angle=swiftshader --enable-unsafe-swiftshader --virtual-time-budget=5000 \
        --dump-dom "http://localhost:$port/web_glclamp.html?v=$$" 2>/dev/null | sed -n 's:.*<title>\(.*\)</title>.*:\1:p')
echo "$title"
case "$title" in PASS*) echo "== web-glclamp: OK ==" ;; *) echo "== web-glclamp: FAILED =="; exit 1 ;; esac
