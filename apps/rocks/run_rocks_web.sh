#!/bin/sh
# run_rocks_web.sh -- the `rocks-web` gate: Rocks itself in a browser -- built for wasm32, run in
# the loader's worker run loop in headless Chrome (cross-origin isolated, the page's DOM services
# from ux_web_page.js) to its window-up line.  Needs a compiler whose loader has the worker hooks
# (compiler 587: the in-tree bin/osx/xcc-xc, with XCC_HOME); skips without one or without Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux=$(cd "$here/../../frameworks/uxkit" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
case "$xcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== rocks-web: skipped (no Chrome) =="; exit 0; }
[ -x "$xcc" ] || { echo "== rocks-web: skipped (no compiler at $xcc) =="; exit 0; }
work=$(mktemp -d)
echo "== rocks-web: building Rocks for wasm32 =="
"$xcc" -A wasm32 -I "$ux" -I "$here/xc" -o "$work/rocks" "$here/xc/rocks_main.xc" -q
grep -q xccPost "$work/rocks.js" || { echo "== rocks-web: skipped (this compiler's loader has no worker hooks) =="; rm -rf "$work"; exit 0; }
cp "$ux/ux_web_browser.js" "$ux/ux_web_page.js" "$here/tools/rocks_web.html" "$work/"
cp "$ux/tools/capture/assets/aristo2.png" "$ux/tools/capture/assets/aristo2-locations.txt" "$work/" 2>/dev/null || true
port=8966
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$ux/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1; rm -rf "$work" 2>/dev/null' EXIT
sleep 1
echo "== rocks-web: headless Chrome =="
( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/rocks_web.html?report" >/dev/null 2>&1 & )
for i in $(seq 1 60); do [ -f "$work/result.txt" ] && break; sleep 1; done
out=$(cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page")
echo "$out" | grep -E '^(PASS|FAIL|SKIP|FRAMES)' | head -3
echo "$out" | grep -q '^FAIL' && { echo "== rocks-web: FAILED =="; exit 1; }
echo "$out" | grep -q '^PASS' || { echo "== rocks-web: FAILED =="; exit 1; }
if [ -n "${ROCKS_WEB_SHOT:-}" ]; then
  # a timed shot (virtual time does not get along with the worker's blocking wait)
  timeout 60 "$CHROME" --headless=new --user-data-dir="$work/chrome2" --window-size=1100,760 --timeout=15000 \
      --screenshot="$ROCKS_WEB_SHOT" "http://localhost:$port/rocks_web.html" >/dev/null 2>&1 || true
fi
echo "== rocks-web: OK — Rocks runs in a browser =="
