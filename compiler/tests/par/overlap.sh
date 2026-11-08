#!/bin/bash
# overlap.sh — a block whose pointer arguments overlap runs serially (#96).
# A loop over two pointers --par-style lifted into a block ran on several
# threads when the pointers were into one array, because the runtime checked
# only arrays it knew the length of, and a plain new array's is not known:
# `o[i] = a[i] * 2 + 7` with o = a + 3 printed 13 33 393209 where the loop
# gives 21 49 589817. The check now bounds such an array by its footprint over
# the run's range. Checked: the overlapping call at every par style and -O
# level; and calls into separate arrays, one array in place, and the two
# halves of one array, which do not overlap and still run as a block.
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# Auto's learned choices are kept per user; these runs keep theirs apart.
export HOME="$W/home"; mkdir -p "$HOME"
if [ "$PLAT" = osx ]; then export DYLD_LIBRARY_PATH=support/runtime-lib/arm64-macos; else export LD_LIBRARY_PATH=support/runtime-lib/$(uname -m | sed 's/aarch64/arm64/')-linux; fi
fail=0
cat > "$W/a.xc" <<'XC'
#import "Stdio.xc"
void step(u32* o, u32* a, u32 n) { for (u32 i = (u32)0; i < n; i++) o[i] = a[i] * (u32)2 + (u32)7; }
i32 main(i32 argc, u8** argv)
    {
    u32* x = new u32[64];
    for (u32 i = (u32)0; i < (u32)64; i++) x[i] = i;
    step(&x[3], &x[0], (u32)50);
    Stdio.printf("%u %u %u\n", x[6], x[9], x[50]);
    return 0;
    }
XC
for o in O0 O2 O3; do
    for st in auto threads cpu; do
        "$XC" -q -$o -H . --par-style=$st -o "$W/a" "$W/a.xc" > "$W/e" 2>&1 || { echo "FAIL overlap: -$o $st: does not build"; fail=1; continue; }
        got=$("$W/a" 2>/dev/null)
        [ "$got" = "21 49 589817" ] || { echo "FAIL overlap: -$o --par-style=$st: $got, not 21 49 589817"; fail=1; }
    done
done
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
void step(u32* o, u32* a, u32 n) { for (u32 i = (u32)0; i < n; i++) o[i] = a[i] * (u32)2 + (u32)7; }
i32 main(i32 argc, u8** argv)
    {
    u32 n = (u32)4000000;
    u32* x = new u32[n]; u32* y = new u32[n];
    for (u32 i = (u32)0; i < n; i++) x[i] = i;
    step(y, x, n);
    step(x, x, n);
    step(&x[n / (u32)2], &x[0], n / (u32)2);
    Stdio.printf("%u %u %u\n", y[6], x[9], x[n - (u32)1]);
    return 0;
    }
XC
"$XC" -q -O3 -H . --par-style=threads -o "$W/b" "$W/b.xc" > "$W/e" 2>&1 || { echo "FAIL overlap: b does not build"; fail=1; }
# The report is on the program's output, each line `par: ...`.
XC_PAR_REPORT=1 "$W/b" > "$W/all" 2>&1
grep -v '^par:' "$W/all" > "$W/out"
grep '^par:' "$W/all" > "$W/err"
[ "$(cat "$W/out")" = "19 25 8000017" ] || { echo "FAIL overlap: apart calls print $(cat "$W/out"), not 19 25 8000017"; fail=1; }
if grep -q 'overlap and one is written' "$W/err"; then
    echo "FAIL overlap: a call whose arrays do not overlap ran serially"; fail=1
fi
[ "$(grep -c 'items on the CPU' "$W/err")" -ge 3 ] || { echo "FAIL overlap: the apart calls did not all run as a block"; fail=1; }
[ $fail -eq 0 ] && echo "--- overlap: overlapping pointer arguments run serially; apart ones as a block ---"
exit $fail
