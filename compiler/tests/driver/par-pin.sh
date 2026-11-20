#!/bin/bash
# par-pin.sh — on Linux a par block's CPU threads are pinned, one a CPU of the
# process's allowed set (ParCpuLanes.pinCpus): under taskset on CPUs 2-5 with
# four threads, the four lanes hold 2, 3, 4 and 5 one each, and the calling
# thread, pinned for the run only, has 2-5 back. XC_PAR_PIN=0 leaves every
# thread on 2-5. Unpinned, a 32-thread Zen 5 now and then ran two threads on
# one CPU and an even block's time jumped by half (#32).
# The lanes start after the CPU the calling thread runs on (#460), so each
# set is run with the program started on each of its CPUs in turn (the
# fixture's argument): the lane the direct path leaves idle, on that CPU, was
# found still holding the whole set now and then (#506). A set with gaps pins
# the same way, and a set smaller than the lanes pins none of them.
cd "$(dirname "$0")/../.."
XC="${XC:-bin/osx/xcc-xc}"
W=$(mktemp -d /tmp/par-pin.XXXX)
trap 'rm -rf "$W"' EXIT
if [ "$(uname -s)" = Linux ]; then RUN() { bash -c "$1"; }; ARCH=""
elif [ -n "${XTC_X86_64_HOST:-}" ]; then RUN() { ssh "$XTC_X86_64_HOST" "$1"; }; ARCH="-A x86_64"
    # The Linux legs run this natively; from a Mac that cannot log in to the
    # host (no key there), say so rather than fail on the copy.
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$XTC_X86_64_HOST" true 2>/dev/null \
        || { echo "par-pin: skipped (cannot log in to $XTC_X86_64_HOST)"; exit 0; }
else echo "par-pin: skipped (no Linux host)"; exit 0; fi
"$XC" -q -H . -O2 $ARCH -o "$W/pin" tests/fixtures/par_pin_cpus.xc || { echo "FAIL par-pin: build"; exit 1; }
R=/tmp/par-pin-$$
if [ -n "$ARCH" ]; then scp -q "$W/pin" "$XTC_X86_64_HOST:$R" || { echo "FAIL par-pin: the copy to $XTC_X86_64_HOST"; exit 1; }; else cp "$W/pin" "$R"; fi
E="XC_PAR=cpu XC_PAR_THREADS=4 XC_SETTINGS_DIR=$R.s"
C=""; want=""
for start in 2 3 4 5 2 3 4 5 2 3 4 5; do
    C="$C $E taskset -c 2,3,4,5 $R $start;"; want="$want"$'2\n2-5\n3\n4\n5\nsum 12288\n'
done
for start in 0 2 3 5 0 2 3 5; do
    C="$C $E taskset -c 0,2,3,5 $R $start;"; want="$want"$'0\n0,2-3,5\n2\n3\n5\nsum 12288\n'
done
out=$(RUN "$C $E taskset -c 2,3,4 $R 3; echo ---; XC_PAR_PIN=0 $E taskset -c 2,3,4,5 $R; rm -rf $R $R.s")
want="$want"$'2-4\n2-4\n2-4\n2-4\n2-4\nsum 12288\n---\n2-5\n2-5\n2-5\n2-5\n2-5\nsum 12288'
if [ "$out" = "$want" ]; then echo "par-pin: ok"; exit 0; fi
echo "FAIL par-pin: wanted one CPU a lane (then, with XC_PAR_PIN=0, none pinned), got:"; echo "$out" | sed 's/^/    /'; exit 1
