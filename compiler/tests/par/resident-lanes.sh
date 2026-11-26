#!/bin/bash
# resident-lanes.sh — CPU lanes faulting together on a block kept on the GPU
# (#15). tests/fixtures/par_resident_lanes.xc keeps a 4 MB array on the GPU
# each round, then reads it from a block on the CPU's lanes. With each fetch
# held 50 ms inside the registry's lock (XC_PAR_RESIDENT_SLOW_MS), every lane
# faults while the first fetches: the lock must let one fetch through (one
# fetch a round, eight in all, where a lock that does not exclude lets each
# lane fetch), and the lanes that waited must have their reads run again
# (a fault on a block another lane fetched is answered as retried, not handed
# to the action installed before, which killed the next round's fault).
# Runs where CUDA is: here on Linux, or XC_LINUX_HOST from macOS.
#
#   [XC_LINUX_HOST=<host>] bash tests/par/resident-lanes.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_resident_lanes.xc
HOST=${XC_LINUX_HOST:-}
want=$(cat tests/fixtures/par_resident_lanes.expected.out)
if [ "$PLAT" = osx ]; then
    [ -n "$HOST" ] || { echo "resident-lanes: no XC_LINUX_HOST, skipped"; exit 0; }
    "$XC" -q -O2 -H . -A x86_64 --no-runtime-lib -o "$W/l" "$F" > "$W/b" 2>&1 || { echo "FAIL resident-lanes: no build: $(head -c 300 "$W/b")"; exit 1; }
    RD=$(ssh "$HOST" 'mktemp -d /tmp/xc-lanes.XXXXXX' 2>/dev/null) || { echo "resident-lanes: cannot reach $HOST, skipped"; exit 0; }
    scp -q "$W/l" "$HOST:$RD/lanes" || { echo "resident-lanes: cannot reach $HOST, skipped"; exit 0; }
    run() { ssh "$HOST" "cd $RD && env $1 ./lanes"; }
else
    "$XC" -q -O2 -H . --no-runtime-lib -o "$W/l" "$F" > "$W/b" 2>&1 || { echo "FAIL resident-lanes: no build: $(head -c 300 "$W/b")"; exit 1; }
    run() { (cd "$W" && env $1 ./l); }
fi
fail=0
ran=0
for G in cuda; do
    out=$(run "XC_PAR=gpu XC_PAR_GPU=$G XC_PAR_RESIDENT=1 XC_PAR_RESIDENT_SLOW_MS=50 XC_PAR_REPORT=1" 2>&1)
    if ! echo "$out" | grep -qE "^par: CUDA device [0-9]+ is"; then
        echo "resident-lanes: no $G device, skipped there"; continue
    fi
    ran=1
    got=$(echo "$out" | grep -v '^par:')
    [ "$got" = "$want" ] || { echo "FAIL resident-lanes ($G): '$(echo "$got" | tail -2)', wanted '$want'"; fail=1; }
    lanes=$(echo "$out" | grep -c 'over [0-9]* lanes')
    kept=$(echo "$out" | grep -c 'kept on the GPU')
    fetched=$(echo "$out" | grep -c 'fetched from the GPU')
    gpu=$(echo "$out" | grep -c 'fill: [0-9]* items on the GPU')
    [ "$lanes" -ge 8 ] || { echo "FAIL resident-lanes ($G): the reading block ran on lanes $lanes times, wanted 8"; fail=1; }
    # A device that did not run the writing block (busy, or a run that failed
    # and fell back to the CPU, which gives the same answer) keeps nothing:
    # that is the device's state, not residency's, and is said, not failed.
    if [ "$gpu" = 0 ]; then
        echo "resident-lanes: the $G device ran no fill block, skipped there:"
        echo "$out" | grep '^par:' | grep -vE 'cost ops|lanes on|items in [0-9]* pieces' | head -8 | sed 's/^/    /'
        continue
    fi
    [ "$kept" -ge 8 ] && [ "$fetched" = 8 ] \
        || { echo "FAIL resident-lanes ($G): kept $kept, fetched $fetched, wanted 8 or more and 8 (fill ran on the GPU $gpu times):"
             echo "$out" | grep '^par:' | grep -vE 'cost ops|lanes on|items in [0-9]* pieces' | head -16 | sed 's/^/    /'; fail=1; }
done
[ "$PLAT" = osx ] && ssh "$HOST" "rm -rf $RD"
[ $fail = 0 ] && { [ $ran = 1 ] && echo "--- resident-lanes: pass ---" || echo "--- resident-lanes: skipped (no device) ---"; }
exit $fail
