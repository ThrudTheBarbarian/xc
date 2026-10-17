#!/bin/bash
# browsers.sh — the web plugin test in real browsers: headless Chrome (DevTools
# protocol) and headless Firefox (WebDriver BiDi), through the threads test's
# drivers. The host page loads the signed bundle beside it, asks (yes), calls
# the plugin and is called back. Not in the gate (it needs the browsers); run
# by hand after a loader change:
#
#   XC=bin/osx/xcc-xc bash tests/bundle/web/browsers.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
D=tests/wasm32/threads
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
FIREFOX=${FIREFOX:-/Applications/Firefox.app/Contents/MacOS/firefox}
NODE=$(command -v node) || { echo "SKIP browsers: no node"; exit 0; }
L=$(mktemp -d "${TMPDIR:-/tmp}/wplug.XXXX"); trap 'rm -rf "$L"' EXIT
mkdir -p "$L/site"
mkdir -p "$L/res"; printf 'signed words' > "$L/res/note.txt"
"$XC" --bundle "$L/site/spice" --bundle-key "$L/key" --bundle-name spice -A wasm32 -o "$L/spice.wasm" \
    --resources "$L/res" tests/bundle/web/spiceweb.xc > /dev/null || { echo "FAIL build plugin"; exit 1; }
"$XC" -q -A wasm32 -H . -o "$L/site/webhost.wasm" tests/bundle/web/webhost.xc || { echo "FAIL build host"; exit 1; }
cat > "$L/site/webhost.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>webhost</title></head><body><pre id="o"></pre>
<script>
const put = (s) => { document.getElementById("o").textContent += s + "\n"; };
globalThis.xccOut = (s) => put("OUT " + s);
globalThis.xccEnv = { PLUGIN: "spice" };
const ce = console.error.bind(console);
console.error = (...a) => { put("ERR " + a.map(String).join(" ")); ce(...a); };
</script><script src="webhost.js"></script></body></html>
HTML
printf '%s\n' "asked about spice (domain '')" "host emit 5 bytes" "host note 17" "run -> 17" "sum -> 10, first byte now 99" "resource: signed words" > "$L/want"
PORT=$((48900 + RANDOM % 300))
python3 $D/serve.py $PORT 0 "$L/site" & SP=$!
sleep 1
rc=0
check() {   # check <browser> <output file>
    grep '^OUT ' "$2" | sed 's/^OUT //' > "$2.out"
    if diff -q "$2.out" "$L/want" > /dev/null; then echo "PASS $1 web plugin"
    else echo "FAIL $1 web plugin"; head -6 "$2"; rc=1; fi
}
if [ -x "$CHROME" ]; then
    DP=$((PORT + 2))
    "$CHROME" --headless=new --user-data-dir="$L/chrome" --remote-debugging-port=$DP about:blank > /dev/null 2>&1 & CP=$!
    sleep 3
    timeout 60 "$NODE" $D/cdp.js "http://127.0.0.1:$PORT/webhost.html" 6 $DP > "$L/chrome.log" 2>&1
    check chrome "$L/chrome.log"
    kill $CP; wait $CP 2> /dev/null
else
    echo "SKIP chrome: none at $CHROME"
fi
if [ -x "$FIREFOX" ]; then
    FP=$((PORT + 3))
    mkdir -p "$L/ff"
    "$FIREFOX" --headless --remote-debugging-port $FP --profile "$L/ff" about:blank > /dev/null 2>&1 & FFP=$!
    sleep 5
    timeout 60 "$NODE" $D/bidi.js "http://127.0.0.1:$PORT/webhost.html" 6 $FP > "$L/firefox.log" 2>&1
    check firefox "$L/firefox.log"
    kill $FFP; wait $FFP 2> /dev/null
else
    echo "SKIP firefox: none at $FIREFOX"
fi
kill $SP; wait $SP 2> /dev/null
echo "--- web plugins in browsers: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
