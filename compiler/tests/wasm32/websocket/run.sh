#!/bin/bash
# run.sh — WebSocket on wasm32: the client (the browser package's WebSocket,
# here Node's) against a native xc echo server over the loopback.
#   XC=bin/osx/xcc-xc bash tests/wasm32/websocket/run.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
D=tests/wasm32/websocket
L=$(mktemp -d "${TMPDIR:-/tmp}/wsw.XXXX"); trap 'rm -rf "$L"' EXIT
command -v node >/dev/null || { echo "SKIP websocket wasm32: no node"; exit 0; }
PORT=$((47300 + RANDOM % 400))
"$XC" -q -O2 -H . -o "$L/server" $D/echo_server.xc > "$L/b1" 2>&1 || { echo "FAIL: server build"; head -3 "$L/b1"; exit 1; }
sed "s/PORT/$PORT/" $D/client.xc > "$L/client.xc"
"$XC" -q -O2 -A wasm32 -H . -o "$L/client.wasm" "$L/client.xc" > "$L/b2" 2>&1 || { echo "FAIL: client build"; head -3 "$L/b2"; exit 1; }
"$L/server" $PORT > "$L/server.out" 2>&1 &
S=$!
for i in $(seq 50); do grep -q listening "$L/server.out" 2>/dev/null && break; sleep 0.1; done
timeout 20 node "$L/client.js" > "$L/client.out" 2>&1
wait $S
if diff -q "$L/client.out" $D/expected.out > /dev/null; then echo "PASS websocket wasm32"; exit 0; fi
echo "FAIL websocket wasm32"; diff "$L/client.out" $D/expected.out; exit 1
