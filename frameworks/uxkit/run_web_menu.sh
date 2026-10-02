#!/bin/sh
# run_web_menu.sh -- the menu bar on the web (a DOM bar, ux_web_page.js): the node rig checks what
# the page is handed and that a pick through the ring fires the item; real headless Chrome checks
# the DOM bar itself -- opening, following the pointer, picking, refusing a greyed item, Escape.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-menu: skipped (no node on PATH) =="; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "== web-menu: building test_web_menu for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_menu" "$here/test_web_menu.xc" -q 2>/dev/null
echo "== web-menu: node rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_menu.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-menu: FAILED (node rig) =="; exit 1; }
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_menu.html" "$work/"
  port=8940
  pkill -f "http.server $port" 2>/dev/null || true
  ( cd "$work" && exec python3 -m http.server $port ) >/dev/null 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null; rm -rf "$work"' EXIT
  sleep 1
  echo "== web-menu: headless Chrome =="
  title=$("$CHROME" --headless=new --virtual-time-budget=5000 --dump-dom "http://localhost:$port/web_menu.html?v=$$" 2>/dev/null \
          | sed -n 's:.*<title>\(.*\)</title>.*:\1:p')
  echo "$title"
  case "$title" in PASS*) ;; *) echo "== web-menu: FAILED (Chrome) =="; exit 1 ;; esac
fi
echo "== web-menu: OK =="
