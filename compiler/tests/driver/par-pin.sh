#!/bin/bash
# par-pin.sh — on Linux a par block's CPU threads are pinned, one a CPU of the
# process's allowed set (ParCpuLanes.pinCpus): under taskset on CPUs 2-5 with
# four threads, the four lanes hold 2, 3, 4 and 5 one each, and the calling
# thread, pinned for the run only, has 2-5 back. XC_PAR_PIN=0 leaves every
# thread on 2-5. Unpinned, a 32-thread Zen 5 now and then ran two threads on
# one CPU and an even block's time jumped by half (#32).
#     bash tests/driver/par-pin.sh        (needs a Linux host with 6+ CPUs:
#                                          native, or XTC_X86_64_HOST)
cd "$(dirname "$0")/../.."
XC="${XC:-bin/osx/xcc-xc}"
W=$(mktemp -d /tmp/par-pin.XXXX)
trap 'rm -rf "$W"' EXIT
if [ "$(uname -s)" = Linux ]; then RUN() { bash -c "$1"; }; ARCH=""
elif [ -n "${XTC_X86_64_HOST:-}" ]; then RUN() { ssh "$XTC_X86_64_HOST" "$1"; }; ARCH="-A x86_64"
else echo "par-pin: skipped (no Linux host)"; exit 0; fi
"$XC" -q -H . -O2 $ARCH -o "$W/pin" tests/fixtures/par_pin_cpus.xc || { echo "FAIL par-pin: build"; exit 1; }
R=/tmp/par-pin-$$
if [ -n "$ARCH" ]; then scp -q "$W/pin" "$XTC_X86_64_HOST:$R" || { echo "FAIL par-pin: the copy to $XTC_X86_64_HOST"; exit 1; }; else cp "$W/pin" "$R"; fi
E="XC_PAR=cpu XC_PAR_THREADS=4 XC_SETTINGS_DIR=$R.s"
out=$(RUN "$E taskset -c 2,3,4,5 $R; echo ---; XC_PAR_PIN=0 $E taskset -c 2,3,4,5 $R; rm -rf $R $R.s")
want=$'2\n2-5\n3\n4\n5\nsum 12288\n---\n2-5\n2-5\n2-5\n2-5\n2-5\nsum 12288'
if [ "$out" = "$want" ]; then echo "par-pin: ok"; exit 0; fi
echo "FAIL par-pin: wanted one CPU a lane (then, with XC_PAR_PIN=0, none pinned), got:"; echo "$out" | sed 's/^/    /'; exit 1
