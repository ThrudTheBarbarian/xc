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
rc=0
# A line in a file, waited for: true once it is there, false after SECS
# seconds (default 120), or as soon as PID (when given) has exited without
# writing it. A loaded gate host can take many seconds to start a daemon or
# to end a connection, so nothing here waits a fixed time.
seen() {
    local f=$1 pat=$2 secs=${3:-120} pid=${4:-} i
    for ((i = 0; i < secs * 10; i++)); do
        grep -q -- "$pat" "$f" 2> /dev/null && return 0
        if [ -n "$pid" ] && ! kill -0 "$pid" 2> /dev/null; then
            grep -q -- "$pat" "$f" 2> /dev/null
            return
        fi
        sleep 0.1
    done
    return 1
}
# daemon LOG [VAR=value ...] -- [xcd arguments]: a daemon, its pid in XPID,
# waited for until it says it is serving and, unless -no-mdns, advertising.
# Each daemon has a log of its own, emptied here before the daemon starts:
# a log reused from an earlier daemon still said "serving" when it was first
# read, and the programs ran before the new daemon listened.
daemon() {
    local log=$1 envs=()
    shift
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    : > "$log"
    env ${envs[@]+"${envs[@]}"} "$L/xcd" "$@" >> "$log" 2>&1 &
    XPID=$!
    if ! seen "$log" 'xcd: serving' 120 $XPID; then
        echo "FAIL remote: a daemon did not start (xcd $*)"; head -5 "$log" | sed 's/^/    /'; rc=1
        return 1
    fi
    case " $* " in *" -no-mdns "*) ;; *) seen "$log" 'xcd: advertising' 30 $XPID ;; esac
    return 0
}
# A program browsing for daemons (XC_PAR_REMOTE=mdns) listens until no
# daemon has answered for a moment, and while none has, up to
# XC_PAR_MDNS_WAIT ms; the browsing runs here allow 3000 ms, for a loaded
# host. A run that found no daemon at all is still run again, up to five
# times: what these cases check is which daemons a program takes, not how
# fast they answer.
browse() {
    local out=$1 i
    shift
    for i in 1 2 3 4 5; do
        "$@" > "$out" 2>&1
        grep -q 'mdns: 0 daemon(s)' "$out" || return 0
    done
}
# A base whose twelve ports (PORT..PORT+11) are all free: a daemon left
# listening on one of them (another run, or one a person started by hand)
# made the sub-test that drew it fail with "cannot listen on the port".
port_free() { ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null; }
for try in $(seq 50); do
    PORT=$((7300 + RANDOM % 500)); ok=1
    for k in $(seq 0 11); do port_free $((PORT + k)) || { ok=0; break; }; done
    [ $ok = 1 ] && break
done
if ! $XC -q -O2 -H . -o "$L/xcd" selfhost/tools/xcd.xc > "$L/xcd.build" 2>&1; then
    echo "FAIL remote: xcd does not build"; cat "$L/xcd.build" | head -5; exit 1
fi
mkdir -p "$L/home1" "$L/home2"
daemon "$L/xcd.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 -- -port $PORT
XCD=$XPID
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
daemon "$L/xcd_pin.log" XCD_HOME="$L/home2" XC_PAR_REPORT=1 -- -port $PORT -no-mdns
XCDP=$XPID
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
daemon "$L/xcd2.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 -- -port $PORT2 -nimby 00:00-23:59
XCD2=$XPID
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
# 2026-10-21). The answer is the local run's. The daemon is on the queue
# for certain (XC_PAR_WORKERS names it, with the CPU to check its tiles):
# with XC_PAR=all a loaded host's own devices could take every tile first.
PORTL=$((PORT + 9))
daemon "$L/xcdl.log" XCD_HOME="$L/home1" XCD_TEST_CORRUPT=1 XC_PAR_REPORT=1 -- -port $PORTL -no-mdns
XCDL=$XPID
f=par_simd_buffers
mkdir -p "$L/st_lie"
XCC_SETTINGS_DIR="$L/st_lie" XC_PAR_REMOTE=127.0.0.1:$PORTL XC_PAR_WORKERS=remote,cpu XC_PAR_REPORT=1 "$L/$f" > "$L/lie.out" 2> "$L/lie.err"
if grep -v '^par:' "$L/lie.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -q 'returned a wrong result' "$L/lie.out"; then
    echo "PASS remote lying daemon dropped"
else
    echo "FAIL remote lying daemon dropped"; grep -v '^par:' "$L/lie.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote' "$L/lie.out" | head -4; rc=1
fi
kill $XCDL 2> /dev/null
wait $XCDL 2> /dev/null
# A daemon of another data layout (XCD_TEST_LAYOUT: 2 + 8*256, a big-endian
# machine with 8-byte pointers) is refused at the handshake, as a block's data
# travels as the program's own bytes: the program says why and runs here.
PORTY=$((PORT + 10))
daemon "$L/xcdy.log" XCD_HOME="$L/home1" XCD_TEST_LAYOUT=2050 XC_PAR_REPORT=1 -- -port $PORTY -no-mdns
XCDY=$XPID
mkdir -p "$L/st_lay"
XCC_SETTINGS_DIR="$L/st_lay" XC_PAR_REMOTE=127.0.0.1:$PORTY XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/lay.out" 2> "$L/lay.err"
if grep -v '^par:' "$L/lay.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && grep -q 'another data layout (big-endian, 8-byte pointers' "$L/lay.out" && ! grep -q 'remote worker remote:' "$L/lay.out"; then
    echo "PASS remote layout mismatch refused"
else
    echo "FAIL remote layout mismatch refused"; grep -v '^par:' "$L/lay.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep -i 'remote' "$L/lay.out" | head -4; rc=1
fi
kill $XCDY 2> /dev/null
wait $XCDY 2> /dev/null
grep -q 'declined (nimby)' "$L/xcd2.log" || { echo "FAIL remote: the nimby daemon did not decline"; head -4 "$L/xcd2.log"; rc=1; }
# Discovery: a daemon advertising in a pool is found by XC_PAR_REMOTE=mdns
# with that pool, and not by another pool. It says it is another machine
# (XC_PAR_MACHINE): a program does not take its own machine's daemon.
PORT3=$((PORT + 2))
daemon "$L/xcd3.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 XC_PAR_MACHINE=gate-other-machine -- -port $PORT3 -pool gate
XCD3=$XPID
mkdir -p "$L/st_mdns" "$L/st_mdns2"
browse "$L/mdns.out" env XCC_SETTINGS_DIR="$L/st_mdns" XC_PAR_MDNS_WAIT=3000 XC_PAR_REMOTE=mdns XC_PAR_POOL=gate XC_PAR=all XC_PAR_REPORT=1 "$L/$f"
XCC_SETTINGS_DIR="$L/st_mdns2" XC_PAR_MDNS_WAIT=3000 XC_PAR_REMOTE=mdns XC_PAR_POOL=other XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/mdns2.out" 2>&1
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
PORTOWN=$((PORT + 11))
daemon "$L/xcd_own.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 -- -port $PORTOWN -pool own
XCDOWN=$XPID
mkdir -p "$L/st_own"
browse "$L/own.out" env XCC_SETTINGS_DIR="$L/st_own" XC_PAR_MDNS_WAIT=3000 XC_PAR_REMOTE=mdns XC_PAR_POOL=own XC_PAR=all XC_PAR_REPORT=1 "$L/$f"
# (The program connects to learn the daemon's machine, so it logs the worker
# before it leaves it out: the daemon's own log says whether it took a block.)
if grep -v '^par:' "$L/own.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && ! grep -q 'taken' "$L/xcd_own.log" \
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
daemon "$L/xcd4.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 XC_PAR_DIE_AFTER=1 -- -port $PORT4 -no-mdns
XCD4=$XPID
mkdir -p "$L/st_die"
# The daemon on the queue for certain (XC_PAR_WORKERS names it, with the CPU
# to take its tiles back), running its first tile and dropping the connection,
# unanswered, on its second (so a tile is always in flight): with XC_PAR=all and two
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
daemon "$L/xcd_two.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 -- -port $PORT5 -no-mdns
XCD5=$XPID
mkdir -p "$L/st_two_a" "$L/st_two_b"
XCC_SETTINGS_DIR="$L/st_two_a" XC_PAR_REMOTE=127.0.0.1:$PORT5 XC_PAR=all XC_PAR_REPORT=2 "$L/$f" > "$L/two_a.out" 2>&1 &
PA=$!
XCC_SETTINGS_DIR="$L/st_two_b" XC_PAR_REMOTE=127.0.0.1:$PORT5 XC_PAR=all XC_PAR_REPORT=2 "$L/$f" > "$L/two_b.out" 2>&1 &
PB=$!
wait $PA; wait $PB
if grep -v '^par:' "$L/two_a.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && grep -v '^par:' "$L/two_b.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && [ "$(grep -c 'a program connected' "$L/xcd_two.log")" = 2 ]; then
    echo "PASS remote two programs"
else
    echo "FAIL remote two programs"; grep -v '^par:' "$L/two_a.out" "$L/two_b.out" | head -4; grep -c 'connected' "$L/xcd_two.log"
    echo "  the daemon's log:"; tail -5 "$L/xcd_two.log" | sed 's/^/    /'
    # Two handshakes at once on a new daemon both fail when the TLS library
    # has no locking (Mbed TLS built without threading): the random generator
    # is shared.
    grep -q 'failed the TLS handshake' "$L/xcd_two.log" \
        && echo "  handshakes failed on the daemon: is ${XC_TLS_LIB:-the libtls it loads} built with Mbed TLS threading?"
    for o in two_a two_b; do
        echo "  $o's report:"; grep '^par:' "$L/$o.out" | head -40 | sed 's/^/    /'
    done
    echo "  the environment: XC_PAR_REMOTE=${XC_PAR_REMOTE-unset} XC_PAR_WORKERS=${XC_PAR_WORKERS-unset} XC_PAR_GPU=${XC_PAR_GPU-unset}"
    rc=1
fi
kill $XCD5 2> /dev/null
wait $XCD5 2> /dev/null
# The daemon's slice cache (protocol 5): a block run again sends hashes, not
# bytes, and the report says so on both sides; a daemon with a 1 MB cache
# evicts under the program's feet, and the tiles come again with their
# bytes, the answer unchanged. The daemon is the one worker
# (XC_PAR_WORKERS=remote), so every run's tiles go to it: with XC_PAR=all a
# loaded host's own GPU and CPU took the later runs' tiles, nothing was asked
# of the cache again, and no eviction showed.
PORT6=$((PORT + 5))
PORT7=$((PORT + 6))
daemon "$L/xcd6.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 -- -port $PORT6 -no-mdns
XCD6=$XPID
daemon "$L/xcd7.log" XCD_HOME="$L/home1" XC_PAR_REPORT=1 -- -port $PORT7 -no-mdns -cache 1
XCD7=$XPID
f=par_simd_buffers
mkdir -p "$L/st_cache" "$L/st_cache_small"
XCC_SETTINGS_DIR="$L/st_cache" XC_PAR_REMOTE=127.0.0.1:$PORT6 XC_PAR_WORKERS=remote XC_PAR_REPORT=2 "$L/$f" > "$L/cache.out" 2>&1
if grep -v '^par:' "$L/cache.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && grep -q 'not sent, cached on the daemon' "$L/cache.out" && grep -q ' slice(s) from the cache' "$L/xcd6.log"; then
    echo "PASS remote cache"
else
    echo "FAIL remote cache"; grep -v '^par:' "$L/cache.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep 'cache' "$L/cache.out" "$L/xcd6.log" | head -4; rc=1
fi
XCC_SETTINGS_DIR="$L/st_cache_small" XC_PAR_REMOTE=127.0.0.1:$PORT7 XC_PAR_WORKERS=remote XC_PAR_REPORT=2 "$L/$f" > "$L/cache_small.out" 2>&1
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
daemon "$L/xcd8.log" XCD_HOME="$L/home1" XCD_VRAM_FREE_MB=1 XC_PAR_REPORT=1 -- -port $PORT8 -no-mdns
XCD8=$XPID
mkdir -p "$L/st_vram"
XCC_SETTINGS_DIR="$L/st_vram" XC_PAR_REMOTE=127.0.0.1:$PORT8 XC_PAR=all XC_PAR_REPORT=1 "$L/$f" > "$L/vram.out" 2>&1
# Up after the program has gone: the daemon logs the end of its session.
seen "$L/xcd8.log" 'xcd: the program went away' 60 $XCD8
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
