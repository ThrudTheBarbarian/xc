#!/bin/sh
# run_web_icon.sh -- the application icon on the web (UXApplication.setIcon): the page's favicon.
# Under the node rig (the recorded icon read back) and, when Chrome is here, in real headless Chrome,
# where the page decodes the <link rel="icon"> it ends up with.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-icon: skipped (no node on PATH) =="; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "== web-icon: building test_web_icon for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_icon" "$here/test_web_icon.xc" -q 2>/dev/null
echo "== web-icon: node rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_icon.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-icon: FAILED (node rig) =="; exit 1; }
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  cp "$here/ux_web_browser.js" "$here/tools/web_icon.html" "$work/"
  port=8938
  pkill -f "http.server $port" 2>/dev/null || true
  ( cd "$work" && exec python3 -m http.server $port ) >/dev/null 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null; rm -rf "$work"' EXIT
  sleep 1
  echo "== web-icon: headless Chrome =="
  title=$("$CHROME" --headless=new --virtual-time-budget=5000 --dump-dom "http://localhost:$port/web_icon.html?v=$$" 2>/dev/null \
          | sed -n 's:.*<title>\(.*\)</title>.*:\1:p')
  echo "$title"
  case "$title" in PASS*) ;; *) echo "== web-icon: FAILED (Chrome) =="; exit 1 ;; esac
fi
echo "== web-icon: OK =="
