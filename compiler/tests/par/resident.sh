#!/bin/bash
# resident.sh — arrays kept on a CUDA device between runs (issue #15,
# XC_PAR_RESIDENT=1). tests/fixtures/par_resident.xc runs a block ten times
# over a 16 MB array it reads and writes; its argument count picks the case.
# Every case prints what the CPU prints, with residency and without. On a
# CUDA device with residency on, the report must show the array kept on the
# device after every run and fetched back exactly when the host touches it:
# once with no access between runs (the read before the final sum), ten times
# with a host read between runs, and ten times with a host write between runs
# (the write then reaching the next run is what the sum checks). Elsewhere
# (no CUDA, Vulkan, Metal) nothing is kept. Both compilers' builds are run
# where they can target the host (here, or XC_LINUX_HOST for x86-64 Linux).
#
#   bash tests/par/resident.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_resident.xc
HOST=${XC_LINUX_HOST:-}
fail=0
# One binary per compiler: native on Linux; on macOS for x86-64 Linux when a
# host is given (CUDA lives there), else for this Mac (Metal: nothing kept).
for C in xcc-xc xcc; do
    XC=bin/$PLAT/$C
    [ -x "$XC" ] || continue
    if [ "$PLAT" = osx ] && [ -n "$HOST" ]; then
        "$XC" -q -O2 -H . -A x86_64 -o "$W/r.$C" "$F" > "$W/b.$C" 2>&1 || { echo "FAIL resident ($C): no build: $(head -c 300 "$W/b.$C")"; fail=1; continue; }
        scp -q "$W/r.$C" "$HOST:/tmp/resident.$C.$$" || { echo "resident: cannot reach $HOST, skipped"; exit 0; }
        run() { ssh "$HOST" "cd /tmp && $1 ./resident.$C.$$ $2"; }
    else
        "$XC" -q -O2 -H . -o "$W/r.$C" "$F" > "$W/b.$C" 2>&1 || { echo "FAIL resident ($C): no build: $(head -c 300 "$W/b.$C")"; fail=1; continue; }
        run() { (cd "$W" && env $1 ./r.$C $2); }
    fi
    cuda=$(run "XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_REPORT=1" "" 2>&1 | grep -c "CUDA device")
    for args in "" "x" "x y"; do
        want=$(run "XC_PAR=cpu" "$args" 2>/dev/null)
        for R in 0 1; do
            out=$(run "XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_RESIDENT=$R XC_PAR_REPORT=1" "$args" 2>&1)
            got=$(echo "$out" | grep -v '^par:')
            [ "$got" = "$want" ] || { echo "FAIL resident ($C, args '$args', R=$R): '$got', wanted '$want'"; fail=1; }
            kept=$(echo "$out" | grep -c 'kept on the GPU')
            fetched=$(echo "$out" | grep -c 'fetched from the GPU')
            if [ "$R" = 1 ] && [ "$cuda" -gt 0 ]; then
                case "$args" in "") wf=1 ;; *) wf=10 ;; esac
                [ "$kept" -ge 10 ] || { echo "FAIL resident ($C, args '$args'): kept $kept times, wanted 10 or more"; fail=1; }
                [ "$fetched" = "$wf" ] || { echo "FAIL resident ($C, args '$args'): fetched $fetched times, wanted $wf"; fail=1; }
            elif [ "$kept" != 0 ] || [ "$fetched" != 0 ]; then
                echo "FAIL resident ($C, args '$args', R=$R): kept $kept, fetched $fetched, wanted none"; fail=1
            fi
        done
    done
    [ "$PLAT" = osx ] && [ -n "$HOST" ] && ssh "$HOST" "rm -f /tmp/resident.$C.$$"
done
[ $fail = 0 ] && echo "resident: ok"
exit $fail
