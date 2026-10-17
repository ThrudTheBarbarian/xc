#!/bin/bash
# browsers.sh — the threads_*.xc fixtures as wasm32 in real browsers: headless
# Chrome (over the DevTools protocol) and headless Firefox (over WebDriver
# BiDi), each page served cross-origin isolated (COOP + COEP) by serve.py,
# its output read back from the page. Then once WITHOUT the headers, where the
# loader must refuse with the message naming them. Not in the gate (it needs
# the two browsers); run by hand after a loader or back-end change:
#
#   XC=bin/osx/xcc-xc bash tests/wasm32/threads/browsers.sh
#
# Safari has no headless mode and its driver needs "Allow Remote Automation",
# so it is checked by hand: serve a page with serve.py and open it.
set -u
cd "$(dirname "$0")/../../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
D=tests/wasm32/threads
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
FIREFOX=${FIREFOX:-/Applications/Firefox.app/Contents/MacOS/firefox}
NODE=$(command -v node) || { echo "SKIP browsers: no node"; exit 0; }
L=$(mktemp -d "${TMPDIR:-/tmp}/wthr.XXXX"); trap 'rm -rf "$L"' EXIT
mkdir -p "$L/site"
page() {   # page <base>: stdout into #o, errors too
    cat > "$L/site/$1.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>$1</title></head><body><pre id="o"></pre>
<script>
const put = (s) => { document.getElementById("o").textContent += s + "\n"; };
globalThis.xccOut = (s) => put("OUT " + s);
const ce = console.error.bind(console);
console.error = (...a) => { put("ERR " + a.map(String).join(" ")); ce(...a); };
</script><script src="$1.js"></script></body></html>
HTML
}
FIX=$(ls tests/fixtures/threads_*.xc)
for f in $FIX; do
    b=$(basename "$f" .xc)
    "$XC" -q -A wasm32 -H . -o "$L/site/$b.wasm" "$f" > "$L/$b.build" 2>&1 || { echo "FAIL $b: build"; continue; }
    page "$b"
done
PORT=$((48600 + RANDOM % 300))
python3 $D/serve.py $PORT 1 "$L/site" & SP=$!
PORT0=$((PORT + 1))
python3 $D/serve.py $PORT0 0 "$L/site" & SP0=$!
sleep 1
rc=0
check() {   # check <browser> <base> <output file>
    grep '^OUT ' "$3" | sed 's/^OUT //' > "$3.out"
    if diff -q "$3.out" "tests/fixtures/$2.expected.out" > /dev/null; then echo "PASS $1 $2"
    else echo "FAIL $1 $2"; head -3 "$3"; rc=1; fi
}
if [ -x "$CHROME" ]; then
    DP=$((PORT + 2))
    "$CHROME" --headless=new --user-data-dir="$L/chrome" --remote-debugging-port=$DP about:blank > /dev/null 2>&1 & CP=$!
    sleep 3
    for f in $FIX; do
        b=$(basename "$f" .xc)
        timeout 60 "$NODE" $D/cdp.js "http://127.0.0.1:$PORT/$b.html" 8 $DP > "$L/chrome_$b" 2>&1
        check chrome "$b" "$L/chrome_$b"
    done
    timeout 60 "$NODE" $D/cdp.js "http://127.0.0.1:$PORT0/threads_spawn_join.html" 4 $DP > "$L/chrome_noiso" 2>&1
    if grep -q 'Cross-Origin-Embedder-Policy: require-corp' "$L/chrome_noiso"; then echo "PASS chrome refuses without isolation"
    else echo "FAIL chrome without isolation"; cat "$L/chrome_noiso"; rc=1; fi
    kill $CP
else
    echo "SKIP chrome: none at $CHROME"
fi
if [ -x "$FIREFOX" ]; then
    n=0
    for f in $FIX; do
        b=$(basename "$f" .xc)
        n=$((n + 1)); FP=$((PORT + 10 + n))
        mkdir -p "$L/ff$n"
        "$FIREFOX" --headless --remote-debugging-port $FP --profile "$L/ff$n" about:blank > /dev/null 2>&1 & FFP=$!
        sleep 5
        timeout 60 "$NODE" $D/bidi.js "http://127.0.0.1:$PORT/$b.html" 8 $FP > "$L/firefox_$b" 2>&1
        check firefox "$b" "$L/firefox_$b"
        kill $FFP; wait $FFP 2> /dev/null
    done
else
    echo "SKIP firefox: none at $FIREFOX"
fi
kill $SP $SP0; wait $SP $SP0 2> /dev/null
echo "--- wasm32 threads in browsers: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
