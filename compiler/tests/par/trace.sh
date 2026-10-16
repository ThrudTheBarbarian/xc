#!/bin/bash
# trace.sh — XC_PAR_TRACE=<file>: a run on the tile queue writes its records
# (tools/par-trace.html draws them), the answer unchanged. Checks the header,
# that every tile handed out came back, and that each run has its END.
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
[ $rc = 0 ] && rm -rf "$L"
echo "--- trace: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
