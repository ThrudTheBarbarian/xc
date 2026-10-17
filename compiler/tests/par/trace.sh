#!/bin/bash
# trace.sh — XC_PAR_TRACE=<file>: a run on the tile queue writes its records
# (tools/par-trace.html draws them), the answer unchanged. Checks the header,
# that every tile handed out came back, and that each run has its END; and
# XC_PAR_TRACE=host:port sends the same records to a listener.
#
#   XC=bin/osx/xcc-xc bash tests/par/trace.sh
set -u
export XC_PAR_REMOTE=none     # discovery is on by default; this test names no daemon
XC=${XC:-bin/osx/xcc-xc}
L=$(mktemp -d "${TMPDIR:-/tmp}/par-trace.XXXX")
f=par_simd_buffers
if ! $XC -q -O2 -H . -o "$L/$f" "tests/fixtures/$f.xc" > "$L/build" 2>&1; then
    echo "FAIL trace: $f does not build"; head -3 "$L/build"; exit 1
fi
mkdir -p "$L/st"
XCC_SETTINGS_DIR="$L/st" XC_PAR=all XC_PAR_TRACE="$L/t.trace" "$L/$f" > "$L/out" 2>&1
rc=0
if ! grep -v '^par:' "$L/out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null; then
    echo "FAIL trace: the answer differs"; rc=1
elif ! python3 - "$L/t.trace" <<'PY'
import sys, struct
b = open(sys.argv[1], 'rb').read()
assert b[:8] == b'XCPTRACE' and struct.unpack_from('<I', b, 8)[0] == 1, "header"
assert (len(b) - 16) % 48 == 0, "record size"
takes, dones, ends, runs = {}, {}, set(), set()
for o in range(16, len(b), 48):
    k, w, _, run = struct.unpack_from('<BBHI', b, o)
    a = struct.unpack_from('<q', b, o + 8)[0]
    runs.add(run)
    if k == 4: takes[(run, a)] = takes.get((run, a), 0) + 1
    if k == 5: dones[(run, a)] = dones.get((run, a), 0) + 1
    if k == 7: ends.add(run)
assert runs and runs == ends, "a run without its END"
assert set(takes) == set(dones), "a tile handed out never came back"
PY
then
    echo "FAIL trace: the file is not as tools/par-trace.html reads it"; rc=1
else
    echo "PASS trace"
fi
# XC_PAR_TRACE=host:port: the same records over TCP to a listener (xcmon's
# feed), the header first.
PORT=$((47600 + RANDOM % 300))
python3 - "$PORT" "$L/net.trace" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); s.settimeout(30)
c, _ = s.accept(); c.settimeout(30)
with open(sys.argv[2], "wb") as f:
    while True:
        d = c.recv(65536)
        if not d: break
        f.write(d)
PY
LP=$!
sleep 1
XCC_SETTINGS_DIR="$L/st" XC_PAR=all XC_PAR_TRACE="127.0.0.1:$PORT" "$L/$f" > "$L/out2" 2>&1
wait $LP
if grep -v '^par:' "$L/out2" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && [ "$(head -c 8 "$L/net.trace" 2>/dev/null)" = XCPTRACE ] && [ $(( ($(wc -c < "$L/net.trace") - 16) % 48 )) = 0 ]; then
    echo "PASS trace host:port"
else
    echo "FAIL trace host:port"; rc=1
fi
[ $rc = 0 ] && rm -rf "$L"
echo "--- trace: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
