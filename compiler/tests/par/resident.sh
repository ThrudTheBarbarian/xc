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
# (no CUDA, Vulkan, Metal) nothing is kept. Learned per block
# (XC_PAR_RESIDENT=auto, the default of a program that is all xc), the array
# stays on the device while the host leaves it alone between runs, and a
# host access between runs makes the block copy back from then on, in the
# next process too; the read after the last run teaches nothing. Both
# compilers' builds are run
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
        # A private directory on the host, removed after: a binary run from
        # /tmp itself would load whatever libRuntime another run left there.
        RD=$(ssh "$HOST" 'mktemp -d /tmp/xc-resident.XXXXXX' 2>/dev/null) || { echo "resident: cannot reach $HOST, skipped"; exit 0; }
        scp -q "$W/r.$C" "$HOST:$RD/resident" || { echo "resident: cannot reach $HOST, skipped"; exit 0; }
        run() { ssh "$HOST" "cd $RD && $1 ./resident $2"; }
    else
        "$XC" -q -O2 -H . -o "$W/r.$C" "$F" > "$W/b.$C" 2>&1 || { echo "FAIL resident ($C): no build: $(head -c 300 "$W/b.$C")"; fail=1; continue; }
        run() { (cd "$W" && env $1 ./r.$C $2); }
    fi
    cuda=$(run "XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_REPORT=1" "" 2>&1 | grep -cE "^par: CUDA device [0-9]+ is")
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
        # Learned per block (XC_PAR_RESIDENT=auto, the default of a program
        # that is all xc): with no host access between runs the array stays
        # on the GPU after every run, as forced; a host read or write between
        # runs fetches it once and the block copies back from then on, in
        # this process and (the settings store) the next.
        out=$(run "XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_RESIDENT=auto XC_PAR_FORGET=1 XC_PAR_REPORT=1" "$args" 2>&1)
        got=$(echo "$out" | grep -v '^par:')
        [ "$got" = "$want" ] || { echo "FAIL resident ($C, args '$args', auto): '$got', wanted '$want'"; fail=1; }
        if [ "$cuda" -gt 0 ]; then
            kept=$(echo "$out" | grep -c 'kept on the GPU')
            fetched=$(echo "$out" | grep -c 'fetched from the GPU')
            learned=$(echo "$out" | grep -c 'copied back after every run from now on')
            case "$args" in
                "") [ "$kept" -ge 10 ] && [ "$fetched" = 1 ] && [ "$learned" = 0 ] \
                        || { echo "FAIL resident ($C, auto, no access): kept $kept, fetched $fetched, learned $learned"; fail=1; } ;;
                # Kept twice (the initialising loop, which --par-style lifts,
                # and step's first run), fetched once, and step learns.
                *)  [ "$kept" = 2 ] && [ "$fetched" = 1 ] && [ "$learned" = 1 ] \
                        || { echo "FAIL resident ($C, auto, args '$args'): kept $kept, fetched $fetched, learned $learned, wanted 2 1 1"; fail=1; }
                    # The next process: step copies back from its first run;
                    # only the initialising loop's output is kept (once).
                    again=$(run "XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_RESIDENT=auto XC_PAR_REPORT=1" "$args" 2>&1)
                    k2=$(echo "$again" | grep -c 'kept on the GPU')
                    l2=$(echo "$again" | grep -c 'copied back after every run from now on')
                    [ "$k2" = 1 ] && [ "$l2" = 0 ] \
                        || { echo "FAIL resident ($C, auto, args '$args'): the next process kept $k2, learned $l2, wanted 1 0"; fail=1; } ;;
            esac
        fi
    done
    # A kept array handed to a system call (Socket.write's send()): the
    # writer brings it back first instead of the call failing with EFAULT.
    if [ "$cuda" -gt 0 ] && [ ! "$PLAT" = osx ]; then
        "$XC" -q -O2 -H . -o "$W/s.$C" tests/fixtures/par_resident_send.xc > "$W/sb.$C" 2>&1 \
            || { echo "FAIL resident ($C): par_resident_send does not build"; fail=1; }
        got=$( (cd "$W" && XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_RESIDENT=1 ./s.$C) 2>/dev/null)
        [ "$got" = "$(cat tests/fixtures/par_resident_send.expected.out)" ] \
            || { echo "FAIL resident ($C): a kept array sent through a socket: '$got'"; fail=1; }
    fi
    # Blocks that hand a kept array on: the next block writes it whole, or
    # half of it, or reads it from another slot, or its reduction takes the
    # slot a kept array is in. Each answers as the CPU does.
    if [ "$cuda" -gt 0 ] && [ ! "$PLAT" = osx ]; then
        for fx in par_writes_own par_vec_chain_sum par_inplace_rounds par_auto_array_reduce; do
            "$XC" -q -O2 -H . -o "$W/f.$C" "tests/fixtures/$fx.xc" > "$W/fb.$C" 2>&1 \
                || { echo "FAIL resident ($C): $fx does not build"; fail=1; continue; }
            got=$( (cd "$W" && env XC_PAR=gpu XC_PAR_GPU=cuda XC_PAR_RESIDENT=1 ./f.$C) 2>/dev/null)
            [ "$got" = "$(cat "tests/fixtures/$fx.expected.out")" ] \
                || { echo "FAIL resident ($C): $fx with outputs kept: '$(echo "$got" | head -2)'"; fail=1; }
        done
    fi
    [ "$PLAT" = osx ] && [ -n "$HOST" ] && ssh "$HOST" "rm -rf $RD"
done
[ $fail = 0 ] && echo "resident: ok"
exit $fail
