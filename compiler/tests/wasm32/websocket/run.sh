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
# A node with a global WebSocket (22 and later); the first on PATH may be older.
NODE=
for n in $(command -v -a node 2>/dev/null) /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$n" ] && "$n" -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null && { NODE=$n; break; }
done
[ -n "$NODE" ] || { echo "SKIP websocket wasm32: no node with WebSocket (22+)"; exit 0; }
PORT=$((47300 + RANDOM % 400))
"$XC" -q -O2 -H . -o "$L/server" $D/echo_server.xc > "$L/b1" 2>&1 || { echo "FAIL: server build"; head -3 "$L/b1"; exit 1; }
sed "s/PORT/$PORT/" $D/client.xc > "$L/client.xc"
"$XC" -q -O2 -A wasm32 -H . -o "$L/client.wasm" "$L/client.xc" > "$L/b2" 2>&1 || { echo "FAIL: client build"; head -3 "$L/b2"; exit 1; }
"$L/server" $PORT > "$L/server.out" 2>&1 &
S=$!
for i in $(seq 50); do grep -q listening "$L/server.out" 2>/dev/null && break; sleep 0.1; done
timeout 20 "$NODE" "$L/client.js" > "$L/client.out" 2>&1
# The server ends after its one client; one that never connected is stopped.
for i in $(seq 50); do kill -0 $S 2>/dev/null || break; sleep 0.1; done
kill $S 2>/dev/null
wait $S 2>/dev/null
if diff -q "$L/client.out" $D/expected.out > /dev/null; then echo "PASS websocket wasm32"; exit 0; fi
echo "FAIL websocket wasm32"; diff "$L/client.out" $D/expected.out; exit 1
