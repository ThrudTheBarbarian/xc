#!/bin/sh
# run_web_sound.sh -- sound on the web (UXSound.play): the node rig checks the samples handed over;
# real headless Chrome checks that they start as AudioBuffer sources when autoplay is allowed, and
# that play() honestly answers false under the default policy (no gesture yet).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-sound: skipped (no node on PATH) =="; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "== web-sound: building test_web_sound for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_sound" "$here/test_web_sound.xc" -q 2>/dev/null
echo "== web-sound: node rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_sound.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-sound: FAILED (node rig) =="; exit 1; }
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  cp "$here/ux_web_browser.js" "$here/tools/web_sound.html" "$work/"
  port=8939
  pkill -f "http.server $port" 2>/dev/null || true
  ( cd "$work" && exec python3 -m http.server $port ) >/dev/null 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null; rm -rf "$work"' EXIT
  sleep 1
  for mode in "2 --autoplay-policy=no-user-gesture-required" "0 --autoplay-policy=document-user-activation-required"; do
    set -- $mode
    echo "== web-sound: headless Chrome ($2) =="
    title=$("$CHROME" --headless=new $2 --virtual-time-budget=5000 --dump-dom "http://localhost:$port/web_sound.html?expect=$1&v=$$" 2>/dev/null \
            | sed -n 's:.*<title>\(.*\)</title>.*:\1:p')
    echo "$title"
    case "$title" in PASS*) ;; *) echo "== web-sound: FAILED (Chrome) =="; exit 1 ;; esac
  done
fi
echo "== web-sound: OK =="
