#!/bin/bash
# remote.sh — the par worker daemon on this machine, serving its GPU to two
# programs over the loopback in turn (XC_PAR_REMOTE), each run on every
# device at once (XC_PAR=all): the local GPU, the remote one and the CPU
# pool. The answers must be the local run's. The second program is the one
# that matters: the daemon has held a different block by then, and a worker
# that remembered a compiled kernel by its source's address ran the first
# program's kernel on the second's data (every remote tile wrong, 0.8.1).
#
#   XC=bin/osx/xcc-xc bash tests/par/remote.sh
set -u
XC=${XC:-bin/osx/xcc-xc}
L=$(mktemp -d "${TMPDIR:-/tmp}/par-remote.XXXX")
PORT=$((7300 + RANDOM % 500))
rc=0
if ! $XC -q -O2 -H . -o "$L/xcd" selfhost/tools/xcd.xc > "$L/xcd.build" 2>&1; then
    echo "FAIL remote: xcd does not build"; cat "$L/xcd.build" | head -5; exit 1
fi
XC_PAR_REPORT=1 "$L/xcd" -port $PORT > "$L/xcd.log" 2>&1 &
XCD=$!
sleep 1
for f in par_footprint par_simd_buffers par_grid_constant; do
    if ! $XC -q -O2 -H . -fpar-kernels=all -o "$L/$f" "tests/fixtures/$f.xc" > "$L/$f.build" 2>&1; then
        echo "FAIL remote: $f does not build"; rc=1; continue
    fi
    mkdir -p "$L/st_$f"
    XCC_SETTINGS_DIR="$L/st_$f" XC_PAR_REMOTE=127.0.0.1:$PORT XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/$f.out" 2> "$L/$f.err"
    if grep -v '^par:' "$L/$f.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null; then
        echo "PASS remote $f"
    else
        echo "FAIL remote $f"; grep -v '^par:' "$L/$f.out" | diff - "tests/fixtures/$f.expected.out" | head -4; rc=1
    fi
done
kill $XCD 2> /dev/null
wait $XCD 2> /dev/null
grep -q 'taken' "$L/xcd.log" || { echo "FAIL remote: the daemon took no block"; cat "$L/xcd.log" | head -5; rc=1; }
grep -q 'round trip' "$L/par_footprint.out" || { echo "FAIL remote: no link measurement reported"; head -3 "$L/par_footprint.out"; rc=1; }
# A daemon inside its nimby window declines every block: the program runs
# without it and gets the same answer.
PORT2=$((PORT + 1))
XC_PAR_REPORT=1 "$L/xcd" -port $PORT2 -nimby 00:00-23:59 > "$L/xcd2.log" 2>&1 &
XCD2=$!
sleep 1
f=par_simd_buffers
mkdir -p "$L/st_nimby"
XCC_SETTINGS_DIR="$L/st_nimby" XC_PAR_REMOTE=127.0.0.1:$PORT2 XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/nimby.out" 2> "$L/nimby.err"
if grep -v '^par:' "$L/nimby.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q 'does not take' "$L/nimby.out"; then
    echo "PASS remote nimby"
else
    echo "FAIL remote nimby"; grep -v '^par:' "$L/nimby.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote' "$L/nimby.out" | head -3; rc=1
fi
kill $XCD2 2> /dev/null
wait $XCD2 2> /dev/null
grep -q 'declined (nimby)' "$L/xcd2.log" || { echo "FAIL remote: the nimby daemon did not decline"; head -4 "$L/xcd2.log"; rc=1; }
# Discovery: a daemon advertising in a pool is found by XC_PAR_REMOTE=mdns
# with that pool, and not by another pool.
PORT3=$((PORT + 2))
XC_PAR_REPORT=1 "$L/xcd" -port $PORT3 -pool gate > "$L/xcd3.log" 2>&1 &
XCD3=$!
sleep 1
mkdir -p "$L/st_mdns" "$L/st_mdns2"
XCC_SETTINGS_DIR="$L/st_mdns" XC_PAR_REMOTE=mdns XC_PAR_POOL=gate XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/mdns.out" 2>&1
XCC_SETTINGS_DIR="$L/st_mdns2" XC_PAR_REMOTE=mdns XC_PAR_POOL=other XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/mdns2.out" 2>&1
if grep -v '^par:' "$L/mdns.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q "remote worker remote:" "$L/mdns.out" \
   && grep -v '^par:' "$L/mdns2.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && ! grep -q "remote worker remote:" "$L/mdns2.out"; then
    echo "PASS remote mdns"
else
    echo "FAIL remote mdns"; grep -i 'mdns\|remote' "$L/mdns.out" "$L/mdns2.out" | head -4; rc=1
fi
kill $XCD3 2> /dev/null
wait $XCD3 2> /dev/null
# A daemon that dies mid-run: its tiles are re-issued to the other workers
# and the answer is still the local run's.
PORT4=$((PORT + 3))
XC_PAR_REPORT=1 XC_PAR_DIE_AFTER=2 "$L/xcd" -port $PORT4 -no-mdns > "$L/xcd4.log" 2>&1 &
XCD4=$!
sleep 1
mkdir -p "$L/st_die"
XCC_SETTINGS_DIR="$L/st_die" XC_PAR_REMOTE=127.0.0.1:$PORT4 XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/die.out" 2>&1
if grep -v '^par:' "$L/die.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q "re-issued" "$L/die.out"; then
    echo "PASS remote lost worker"
else
    echo "FAIL remote lost worker"; grep -v '^par:' "$L/die.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote\|re-issued\|lost' "$L/die.out" | head -4; rc=1
fi
kill $XCD4 2> /dev/null
wait $XCD4 2> /dev/null
[ $rc = 0 ] && rm -rf "$L"
echo "--- remote: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
