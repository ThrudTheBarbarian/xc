#!/bin/bash
# pieces.sh — the CPU path's pieces (2026-10-21): a block on the CPU is cut
# into more pieces than there are lanes (8 a lane, none under 256 items) and
# the lanes claim them as they finish, so a loop whose iterations cost unequal
# amounts keeps every lane busy (mandelbrot: 4 lanes were no faster than 2
# with one equal part each). Each piece keeps its own partial and they are
# merged in piece order, so a float sum gives the same bits every run. Each
# lane runs its own group of pieces before another's, and a block with no
# nested loop (its items cost the same) takes one piece a lane.
#
#   bash tests/par/pieces.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 65536
i32 main(i32 argc, u8** argv)
    {
    double total = 0.0;
    par skewed :reduce(+ total)
        {
        for (u32 i in 0..N)
            {
            // The first eighth costs a hundred times the rest.
            u32 rounds = i < (u32)(N / 8) ? (u32)400 : (u32)4;
            double x = (double)i * 0.001;
            for (u32 r in 0..rounds)
                x = x * 0.999 + 0.37;
            total = total + x;
            }
        }
    Stdio.printf("%.17g\n", total);
    return 0;
    }
XC
"$XC" -q -O2 -H . -o "$W/p" "$W/p.xc" > "$W/p.b" 2>&1 || { echo "FAIL pieces: does not build"; head -3 "$W/p.b"; exit 1; }
# The report (XC_PAR_REPORT) goes to the output too, before the result.
XC_PAR=cpu XC_PAR_THREADS=4 XC_PAR_REPORT=1 "$W/p" > "$W/r1" 2>&1
grep -q 'items in 32 pieces over 4 lanes' "$W/r1" || { echo "FAIL pieces: not cut into 32 pieces over 4 lanes:"; head -3 "$W/r1"; fail=1; }
tail -1 "$W/r1" > "$W/o1"
for k in 2 3 4; do
    XC_PAR=cpu XC_PAR_THREADS=4 "$W/p" > "$W/o$k" 2>/dev/null
    cmp -s "$W/o1" "$W/o$k" || { echo "FAIL pieces: run $k gives $(cat "$W/o$k"), run 1 $(cat "$W/o1")"; fail=1; }
done
one=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/p" 2>/dev/null)
awk -v a="$one" -v b="$(cat "$W/o1")" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1e-9 * (a < 0 ? -a : a)) }' \
    || { echo "FAIL pieces: 4 lanes give $(cat "$W/o1"), one thread $one"; fail=1; }
# An even block (no nested loop: every item costs the same) takes one piece a
# lane, each lane its own equal part, as 0.85 did (2026-10-24: eight claimed
# pieces cost a memory-bound saxpy 1.26x on 32 threads, its parts moving
# between caches from run to run).
cat > "$W/e.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 65536
u32 xs[N];
u32 ys[N];
i32 main(void)
    {
    for (u32 i in 0..N) { xs[i] = i * (u32)7; ys[i] = i; }
    u32 total = (u32)0;
    par even :reduce(+ total)
        {
        for (u32 i in 0..N)
            {
            u32 v = (u32)3 * xs[i] + ys[i];
            ys[i] = v;
            total = total + v;
            }
        }
    Stdio.printf("%u\n", total);
    return 0;
    }
XC
"$XC" -q -O2 -H . -o "$W/e" "$W/e.xc" > "$W/e.b" 2>&1 || { echo "FAIL pieces: the even block does not build"; head -3 "$W/e.b"; exit 1; }
XC_PAR=cpu XC_PAR_THREADS=4 XC_PAR_REPORT=1 "$W/e" > "$W/e1" 2>&1
grep -q 'items in 4 pieces over 4 lanes' "$W/e1" || { echo "FAIL pieces: the even block is not one piece a lane:"; grep pieces "$W/e1" | head -2; fail=1; }
[ "$(tail -1 "$W/e1")" = "$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/e" 2>/dev/null)" ] || { echo "FAIL pieces: the even block's 4 lanes and one thread differ"; fail=1; }
[ $fail = 0 ] && echo "--- pieces: pass ---" || echo "--- pieces: FAIL ---"
exit $fail
