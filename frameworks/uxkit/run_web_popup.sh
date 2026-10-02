#!/bin/sh
# run_web_popup.sh -- a popup button's list on the web (ux_web_page.js): the node rig checks the hand-over
# and that the pick through the ring selects and fires once; real headless Chrome shows and clicks the list.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-popup: skipped (no node on PATH) =="; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "== web-popup: building test_web_popup for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_popup" "$here/test_web_popup.xc" -q 2>/dev/null
echo "== web-popup: node rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_popup.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-popup: FAILED (node rig) =="; exit 1; }
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_popup.html" "$work/"
  port=8942
  pkill -f "http.server $port" 2>/dev/null || true
  ( cd "$work" && exec python3 -m http.server $port ) >/dev/null 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null; rm -rf "$work"' EXIT
  sleep 1
  echo "== web-popup: headless Chrome =="
  title=$("$CHROME" --headless=new --virtual-time-budget=5000 --dump-dom "http://localhost:$port/web_popup.html?v=$$" 2>/dev/null \
          | sed -n 's:.*<title>\(.*\)</title>.*:\1:p')
  echo "$title"
  case "$title" in PASS*) ;; *) echo "== web-popup: FAILED (Chrome) =="; exit 1 ;; esac
fi
echo "== web-popup: OK =="
