#!/bin/bash
# remote.sh — the par worker daemon on this machine, serving its GPU to two
# programs over the loopback in turn (XC_PAR_REMOTE), each run on every
# device at once (XC_PAR=all): the local GPU, the remote one and the CPU
# pool. The answers must be the local run's. The second program is the one
# that matters: the daemon has held a different block by then, and a worker
# that remembered a compiled kernel by its source's address ran the first
# program's kernel on the second's data (every remote tile wrong, 0.8.1).
#
# Every connection is TLS: each daemon has its own certificate directory
# here (XCD_HOME), and a program pins the certificate it sees first; a
# daemon with another certificate on a pinned address is refused and the
# program runs on without it.
#
#   XC=bin/osx/xcc-xc bash tests/par/remote.sh
set -u
XC=${XC:-bin/osx/xcc-xc}
L=$(mktemp -d "${TMPDIR:-/tmp}/par-remote.XXXX")
# Each daemon is waited for until it says it is serving (a loaded gate host
# can take longer than a fixed second to start one).
up() {
    for log in "$@"; do
        for i in $(seq 300); do grep -q 'xcd: serving' "$log" 2>/dev/null && break; sleep 0.1; done
    done
}
# A base whose ten ports (PORT..PORT+9) are all free: a daemon left
# listening on one of them (another run, or one a person started by hand)
# made the sub-test that drew it fail with "cannot listen on the port".
port_free() { ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null; }
for try in $(seq 50); do
    PORT=$((7300 + RANDOM % 500)); ok=1
    for k in 0 1 2 3 4 5 6 7 8 9; do port_free $((PORT + k)) || { ok=0; break; }; done
    [ $ok = 1 ] && break
done
rc=0
if ! $XC -q -O2 -H . -o "$L/xcd" selfhost/tools/xcd.xc > "$L/xcd.build" 2>&1; then
    echo "FAIL remote: xcd does not build"; cat "$L/xcd.build" | head -5; exit 1
fi
mkdir -p "$L/home1" "$L/home2"
XCD_HOME="$L/home1" XC_PAR_REPORT=1 "$L/xcd" -port $PORT > "$L/xcd.log" 2>&1 &
XCD=$!
up "$L/xcd.log"
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
grep -q 'certificate .* pinned' "$L/par_footprint.out" || { echo "FAIL remote: no certificate pinned"; grep -i 'remote' "$L/par_footprint.out" | head -3; rc=1; }
grep -q '^tls.pin.127.0.0.1:'$PORT' = ' "$L/st_par_footprint/par.conf" || { echo "FAIL remote: no pin in the settings"; cat "$L/st_par_footprint/par.conf"; rc=1; }
# Another daemon with another certificate on the pinned address: refused,
# and the answer is the local run's.
XCD_HOME="$L/home2" XC_PAR_REPORT=1 "$L/xcd" -port $PORT -no-mdns > "$L/xcd_pin.log" 2>&1 &
XCDP=$!
up "$L/xcd_pin.log"
f=par_footprint
XCC_SETTINGS_DIR="$L/st_$f" XC_PAR_REMOTE=127.0.0.1:$PORT XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/pin.out" 2> "$L/pin.err"
if grep -v '^par:' "$L/pin.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q 'certificate changed' "$L/pin.out"; then
    echo "PASS remote certificate changed"
else
    echo "FAIL remote certificate changed"; grep -v '^par:' "$L/pin.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote\|certificate' "$L/pin.out" | head -3; rc=1
fi
kill $XCDP 2> /dev/null
wait $XCDP 2> /dev/null
# A daemon inside its nimby window declines every block: the program runs
# without it and gets the same answer.
PORT2=$((PORT + 1))
XCD_HOME="$L/home1" XC_PAR_REPORT=1 "$L/xcd" -port $PORT2 -nimby 00:00-23:59 > "$L/xcd2.log" 2>&1 &
XCD2=$!
up "$L/xcd2.log"
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
# A daemon that lies (XCD_TEST_CORRUPT: every slice it returns has a byte
# flipped): the program checks an exact block's remote tiles against the CPU,
# keeps the CPU's answer and drops the daemon, saying so (security review,
# 2026-10-21). The answer is the local run's.
PORTL=$((PORT + 9))
XCD_HOME="$L/home1" XCD_TEST_CORRUPT=1 XC_PAR_REPORT=1 "$L/xcd" -port $PORTL -no-mdns > "$L/xcdl.log" 2>&1 &
XCDL=$!
up "$L/xcdl.log"
f=par_simd_buffers
mkdir -p "$L/st_lie"
XCC_SETTINGS_DIR="$L/st_lie" XC_PAR_REMOTE=127.0.0.1:$PORTL XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/lie.out" 2> "$L/lie.err"
if grep -v '^par:' "$L/lie.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q 'returned a wrong result' "$L/lie.out"; then
    echo "PASS remote lying daemon dropped"
else
    echo "FAIL remote lying daemon dropped"; grep -v '^par:' "$L/lie.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote' "$L/lie.out" | head -4; rc=1
fi
kill $XCDL 2> /dev/null
wait $XCDL 2> /dev/null
grep -q 'declined (nimby)' "$L/xcd2.log" || { echo "FAIL remote: the nimby daemon did not decline"; head -4 "$L/xcd2.log"; rc=1; }
# Discovery: a daemon advertising in a pool is found by XC_PAR_REMOTE=mdns
# with that pool, and not by another pool. It says it is another machine
# (XC_PAR_MACHINE): a program does not take its own machine's daemon.
PORT3=$((PORT + 2))
XCD_HOME="$L/home1" XC_PAR_REPORT=1 XC_PAR_MACHINE=gate-other-machine "$L/xcd" -port $PORT3 -pool gate > "$L/xcd3.log" 2>&1 &
XCD3=$!
up "$L/xcd3.log"
mkdir -p "$L/st_mdns" "$L/st_mdns2"
XCC_SETTINGS_DIR="$L/st_mdns" XC_PAR_REMOTE=mdns XC_PAR_POOL=gate XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/mdns.out" 2>&1
XCC_SETTINGS_DIR="$L/st_mdns2" XC_PAR_REMOTE=mdns XC_PAR_POOL=other XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/mdns2.out" 2>&1
# Neither XC_PAR_REMOTE nor XC_PAR_POOL: no discovery at all (it used to be
# on by default, which sent a program's data to whatever answered).
mkdir -p "$L/st_mdns3"
env -u XC_PAR_REMOTE -u XC_PAR_POOL XCC_SETTINGS_DIR="$L/st_mdns3" XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/mdns3.out" 2>&1
if grep -q 'mdns:\|remote worker remote:' "$L/mdns3.out"; then
    echo "FAIL remote: a program with no XC_PAR_REMOTE or XC_PAR_POOL browsed for daemons"; grep -i 'mdns\|remote' "$L/mdns3.out" | head -3; rc=1
fi
if grep -v '^par:' "$L/mdns.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q "remote worker remote:" "$L/mdns.out" \
   && grep -v '^par:' "$L/mdns2.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && ! grep -q "remote worker remote:" "$L/mdns2.out"; then
    echo "PASS remote mdns"
else
    echo "FAIL remote mdns"; grep -i 'mdns\|remote' "$L/mdns.out" "$L/mdns2.out" | head -4; rc=1
fi
kill $XCD3 2> /dev/null
wait $XCD3 2> /dev/null
# This machine's own daemon, found through mDNS, is not a remote worker:
# its devices are the program's already.
PORTOWN=$((PORT + 9))
XCD_HOME="$L/home1" XC_PAR_REPORT=1 "$L/xcd" -port $PORTOWN -pool own > "$L/xcd5.log" 2>&1 &
XCDOWN=$!
up "$L/xcd5.log"
mkdir -p "$L/st_own"
XCC_SETTINGS_DIR="$L/st_own" XC_PAR_REMOTE=mdns XC_PAR_POOL=own XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/own.out" 2>&1
# (The program connects to learn the daemon's machine, so it logs the worker
# before it leaves it out: the daemon's own log says whether it took a block.)
if grep -v '^par:' "$L/own.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && ! grep -q 'taken' "$L/xcd5.log" \
   && grep -q "this machine's own daemon" "$L/own.out"; then
    echo "PASS remote own machine"
else
    echo "FAIL remote own machine: the program took its own machine's daemon"; grep -i 'mdns\|remote' "$L/own.out" | head -4; rc=1
fi
kill $XCDOWN 2> /dev/null
wait $XCDOWN 2> /dev/null
# A daemon that dies mid-run: its tiles are re-issued to the other workers
# and the answer is still the local run's.
PORT4=$((PORT + 3))
XCD_HOME="$L/home1" XC_PAR_REPORT=1 XC_PAR_DIE_AFTER=1 "$L/xcd" -port $PORT4 -no-mdns > "$L/xcd4.log" 2>&1 &
XCD4=$!
up "$L/xcd4.log"
mkdir -p "$L/st_die"
# The daemon on the queue for certain (XC_PAR_WORKERS names it, with the CPU
# to take its tiles back), dying after its first: with XC_PAR=all and two
# tiles to live it was sometimes handed too few to die, so nothing was
# re-issued (gate 4310).
XCC_SETTINGS_DIR="$L/st_die" XC_PAR_REMOTE=127.0.0.1:$PORT4 XC_PAR_WORKERS=remote,cpu XC_PAR_REPORT=1 "$L/$f" > "$L/die.out" 2>&1
if grep -v '^par:' "$L/die.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q "re-issued" "$L/die.out"; then
    echo "PASS remote lost worker"
else
    echo "FAIL remote lost worker"; grep -v '^par:' "$L/die.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote\|re-issued\|lost' "$L/die.out" | head -4; rc=1
fi
kill $XCD4 2> /dev/null
wait $XCD4 2> /dev/null
# Two programs on one daemon at once: the GPUs serve one run at a time and
# both answers are right.
PORT5=$((PORT + 4))
XCD_HOME="$L/home1" XC_PAR_REPORT=1 "$L/xcd" -port $PORT5 -no-mdns > "$L/xcd5.log" 2>&1 &
XCD5=$!
up "$L/xcd5.log"
mkdir -p "$L/st_two_a" "$L/st_two_b"
XCC_SETTINGS_DIR="$L/st_two_a" XC_PAR_REMOTE=127.0.0.1:$PORT5 XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/two_a.out" 2>&1 &
PA=$!
XCC_SETTINGS_DIR="$L/st_two_b" XC_PAR_REMOTE=127.0.0.1:$PORT5 XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/two_b.out" 2>&1 &
PB=$!
wait $PA; wait $PB
if grep -v '^par:' "$L/two_a.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -v '^par:' "$L/two_b.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && [ "$(grep -c 'a program connected' "$L/xcd5.log")" = 2 ]; then
    echo "PASS remote two programs"
else
    echo "FAIL remote two programs"; grep -v '^par:' "$L/two_a.out" "$L/two_b.out" | head -4; grep -c 'connected' "$L/xcd5.log"
    echo "  the daemon's log:"; tail -5 "$L/xcd5.log" | sed 's/^/    /'
    echo "  what the programs said of it:"; grep -h 'remote' "$L/two_a.out" "$L/two_b.out" | head -6 | sed 's/^/    /'; rc=1
fi
kill $XCD5 2> /dev/null
wait $XCD5 2> /dev/null
# The daemon's slice cache (protocol 5): a block run again sends hashes, not
# bytes, and the report says so on both sides; a daemon with a 1 MB cache
# evicts under the program's feet, and the tiles come again with their
# bytes, the answer unchanged.
PORT6=$((PORT + 5))
PORT7=$((PORT + 6))
XCD_HOME="$L/home1" XC_PAR_REPORT=1 "$L/xcd" -port $PORT6 -no-mdns > "$L/xcd6.log" 2>&1 &
XCD6=$!
XCD_HOME="$L/home1" XC_PAR_REPORT=1 "$L/xcd" -port $PORT7 -no-mdns -cache 1 > "$L/xcd7.log" 2>&1 &
XCD7=$!
up "$L/xcd6.log" "$L/xcd7.log"
f=par_simd_buffers
mkdir -p "$L/st_cache" "$L/st_cache_small"
XCC_SETTINGS_DIR="$L/st_cache" XC_PAR_REMOTE=127.0.0.1:$PORT6 XC_PAR=all XC_PAR_REPORT=2 "$L/$f" > "$L/cache.out" 2>&1
if grep -v '^par:' "$L/cache.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && grep -q 'not sent, cached on the daemon' "$L/cache.out" && grep -q ' slice(s) from the cache' "$L/xcd6.log"; then
    echo "PASS remote cache"
else
    echo "FAIL remote cache"; grep -v '^par:' "$L/cache.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep 'cache' "$L/cache.out" "$L/xcd6.log" | head -4; rc=1
fi
XCC_SETTINGS_DIR="$L/st_cache_small" XC_PAR_REMOTE=127.0.0.1:$PORT7 XC_PAR=all XC_PAR_REPORT=2 "$L/$f" > "$L/cache_small.out" 2>&1
if grep -v '^par:' "$L/cache_small.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && grep -q 'sent again, its slices gone' "$L/cache_small.out"; then
    echo "PASS remote cache evicted"
else
    echo "FAIL remote cache evicted"; grep -v '^par:' "$L/cache_small.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -c 'sent again' "$L/cache_small.out"; rc=1
fi
kill $XCD6 $XCD7 2> /dev/null
wait $XCD6 2> /dev/null
wait $XCD7 2> /dev/null
# The load check: a daemon told it has 1 MB of device memory free declines
# the block with the figures, stays up, and the answer is the local run's.
PORT8=$((PORT + 7))
XCD_HOME="$L/home1" XCD_VRAM_FREE_MB=1 XC_PAR_REPORT=1 "$L/xcd" -port $PORT8 -no-mdns > "$L/xcd8.log" 2>&1 &
XCD8=$!
up "$L/xcd8.log"
mkdir -p "$L/st_vram"
XCC_SETTINGS_DIR="$L/st_vram" XC_PAR_REMOTE=127.0.0.1:$PORT8 XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/vram.out" 2>&1
sleep 1
if grep -v '^par:' "$L/vram.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && grep -q 'needs .* MB of device memory there' "$L/vram.out" && kill -0 $XCD8 2> /dev/null; then
    echo "PASS remote vram check"
else
    echo "FAIL remote vram check"; grep 'device memory' "$L/vram.out" "$L/xcd8.log" | head -3; kill -0 $XCD8 2> /dev/null || echo "    the daemon died"; rc=1
fi
kill $XCD8 2> /dev/null
wait $XCD8 2> /dev/null
[ $rc = 0 ] && rm -rf "$L"
echo "--- remote: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
