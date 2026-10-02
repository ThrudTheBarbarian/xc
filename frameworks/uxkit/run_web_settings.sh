#!/bin/sh
# run_web_settings.sh -- the `web-settings` gate: UXKit's settings persist on the web.  One page
# loaded twice in one headless-Chrome profile: the first load writes (localStorage), the second
# must read it all back.  Skips cleanly without Chrome.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "== web-settings: skipped (no Chrome) =="; exit 0; }
work=$(mktemp -d)
echo "== web-settings: building test_web_settings for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_settings" "$here/test_web_settings.xc" -q 2>/dev/null
cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_settings.html" "$work/"
port=8964
pkill -f "coi_server.py $port" 2>/dev/null || true
( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; rm -rf "$work"' EXIT
sleep 1
load() {
  rm -f "$work/result.txt"
  ( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_settings.html" >/dev/null 2>&1 & )
  for i in $(seq 1 30); do [ -f "$work/result.txt" ] && break; sleep 1; done
  # Chrome writes localStorage to disk lazily: let it settle before the browser is stopped
  sleep 4
  pkill -f "user-data-dir=$work/chrome" 2>/dev/null || true
  sleep 1
  cat "$work/result.txt" 2>/dev/null || echo "FAIL: no result from the page"
}
echo "== web-settings: first load (writes) =="
one=$(load); echo "$one"
echo "$one" | grep -q '^PASS1' || { echo "== web-settings: FAILED (the first load) =="; exit 1; }
echo "== web-settings: second load (reads back) =="
two=$(load); echo "$two"
echo "$two" | grep -q '^PASS:' || { echo "== web-settings: FAILED =="; exit 1; }
echo "== web-settings: OK =="
