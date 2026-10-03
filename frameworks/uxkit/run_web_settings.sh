#!/bin/sh
# run_web_settings.sh -- the `web-settings` gate: UXKit's settings persist on the web.  One page
# loaded twice in one headless-Chrome profile: the first load writes (localStorage), the second
# must read it all back.  Then the same in the WORKER run loop, where the worker has no localStorage
# (its writes go to the page; reads come from the snapshot in xccConfig.workerData), built with the
# in-tree xcc-xc (XCC_WORKER), which has the worker hooks.  Skips cleanly without Chrome.
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
page=web_settings.html
load() {
  rm -f "$work/result.txt"
  ( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/$page" >/dev/null 2>&1 & )
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

xw=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
if [ -x "$xw" ]; then
  echo "== web-settings: the worker run loop (a fresh profile) =="
  "$xw" -A wasm32 -I "$here" -o "$work/test_web_settings" "$here/test_web_settings.xc" -q
  cp "$here/tools/web_settings_worker.html" "$work/"
  rm -rf "$work/chrome"
  page=web_settings_worker.html
  one=$(load); echo "$one"
  echo "$one" | grep -q '^PASS1' || { echo "== web-settings: FAILED (the worker's first load) =="; exit 1; }
  two=$(load); echo "$two"
  echo "$two" | grep -q '^PASS:' || { echo "== web-settings: FAILED (the worker read nothing back) =="; exit 1; }
else
  echo "(no in-tree xcc-xc: the worker leg is skipped)"
fi
echo "== web-settings: OK =="
