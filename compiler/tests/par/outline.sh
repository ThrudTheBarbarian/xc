#!/bin/bash
# outline.sh — IR outlining (XC_PAR_PROPOSE=outline, stages 1-3 of moving
# --par-auto into the IR; cpp-front-end.md): every loop Propose would wrap
# becomes a function of its own, called once in its place; in a program with
# the par runtime, one whose shape allows becomes a block the runtime runs on
# every core (ParFnChunk). Either way the program gives the output it gives
# without. Self-hosted compiler only while it is experimental. The corpus
# check is the same comparison over every fixture.
#
#   bash tests/par/outline.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/o.xc" <<'XC'
#import "Stdio.xc"
#define N 1000
double a[N];
double x[N];
u32 m[N];
void scale(double* d, double* s, double k, i32 n)
    {
    for (i32 i = 0; i < n; i++)
        d[i] = k * s[i];
    }
i32 main(void)
    {
    for (i32 i = 0; i < N; i++)
        x[i] = i;
    scale(a, x, 2.0, N);
    double s = 0.0;
    for (i32 i = 0; i < N; i++)
        s = s + a[i];
    u32 big = (u32)0;
    for (u32 i in 0..N)
        {
        m[i] = (i * (u32)7919) % (u32)1000;
        if (m[i] > big)
            big = m[i];
        }
    i32 last = 0;
    while (last < N && a[last] < 500.0)
        last = last + 1;
    Stdio.printf("%.0f %u %ld\n", s, big, last);
    return 0;
    }
XC
"$XC" -q -O3 -H . "$W/o.xc" -o "$W/plain" >"$W/b1" 2>&1 || { echo "FAIL outline: the plain build"; head -3 "$W/b1"; fail=1; }
XC_PAR_OUTLINE_TRACE=1 XC_PAR_PROPOSE=outline "$XC" -q -O3 -H . "$W/o.xc" -o "$W/out" >"$W/b2" 2>&1 || { echo "FAIL outline: the outlined build"; head -3 "$W/b2"; fail=1; }
if [ $fail = 0 ]; then
    [ "$("$W/plain")" = "$("$W/out")" ] || { echo "FAIL outline: the outlined program's output differs: $("$W/out")"; fail=1; }
    [ "$("$W/plain")" = "999000 999 250" ] || { echo "FAIL outline: the plain program's output: $("$W/plain")"; fail=1; }
    # scale's loop, the fill and the max loop (the float sum needs
    # :goal(speed), the while loop has a second way out).
    n=$(grep -c ': outlined, ' "$W/b2")
    [ "$n" -ge 3 ] || { echo "FAIL outline: $n loops outlined, wanted 3"; fail=1; }
fi
# Blocks: maps (one calling Math.sqrt), sums by + ^ and *, and a loop each
# of whose iterations reads the one before stays a loop.
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"
#define N 200000
u32 a[N];
u32 b[N];
double x[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        a[i] = i * (u32)2654435761;
    for (u32 i in 0..N)
        x[i] = (double)(a[i] >> (u32)20) * 0.5;
    // A class with a static initialiser in the loop: its guard runs in the
    // block, thread-safe.
    for (u32 i in 0..N)
        x[i] = Math.sqrt(x[i]) + 1.0;
    u64 total = (u64)0;
    for (u32 i in 0..N)
        total = total + (u64)(a[i] >> (u32)3);
    u32 mix = (u32)0;
    for (u32 i in 0..N)
        mix = mix ^ a[i];
    u32 odd = (u32)1;
    for (u32 i in 0..64)
        odd = odd * ((a[i] | (u32)1) & (u32)7);
    b[0] = (u32)1;
    for (u32 i in 1..N)
        b[i] = b[i - 1] + (u32)3;
    Stdio.printf("%lu %u %u %u %.1f\n", total, mix, odd, b[N - 1], x[N - 1]);
    return 0;
    }
XC
"$XC" -q -O3 -H . "$W/b.xc" -o "$W/bplain" >"$W/b3" 2>&1 || { echo "FAIL outline: the plain block program"; head -3 "$W/b3"; fail=1; }
XC_PAR_OUTLINE_TRACE=1 XC_PAR_PROPOSE=outline "$XC" -q -O3 -H . "$W/b.xc" -o "$W/bout" >"$W/b4" 2>&1 || { echo "FAIL outline: the outlined block program"; head -3 "$W/b4"; fail=1; }
if [ -x "$W/bplain" ] && [ -x "$W/bout" ]; then
    want=$("$W/bplain")
    for t in 1 3 8; do
        [ "$(XC_PAR_THREADS=$t "$W/bout")" = "$want" ] || { echo "FAIL outline: the blocks' output with $t threads: $(XC_PAR_THREADS=$t "$W/bout")"; fail=1; }
    done
    n=$(grep -c ': outlined, a block' "$W/b4")
    [ "$n" -ge 6 ] || { echo "FAIL outline: $n blocks, wanted 6"; fail=1; }
fi
# Pointers that may be one array: a check at the call runs the block
# serially where their ranges overlap (scale(x + 1, x) copies each element
# into the next, which only a serial run does as written).
cat > "$W/g.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 1000000
void scale(double* d, double* s, double k, i32 n)
    {
    for (i32 i = 0; i < n; i++)
        d[i] = k * s[i];
    }
i32 main(void)
    {
    double* x = new double[N + 8];
    double* y = new double[N];
    for (i32 i = 0; i < N + 8; i++)
        x[i] = i;
    scale(y, x, 2.0, N);
    Stdio.printf("%.0f %.0f\n", y[1], y[N - 1]);
    scale(x + 1, x, 1.0, N);
    Stdio.printf("%.0f %.0f\n", x[2], x[N]);
    return 0;
    }
XC
XC_PAR_OUTLINE_TRACE=1 XC_PAR_PROPOSE=outline "$XC" -q -O3 -H . "$W/g.xc" -o "$W/gout" >"$W/b5" 2>&1 || { echo "FAIL outline: the overlap program"; head -3 "$W/b5"; fail=1; }
if [ -x "$W/gout" ]; then
    grep -q 'scale:[0-9]*: outlined, a block' "$W/b5" || { echo "FAIL outline: scale's loop is not a block"; fail=1; }
    for t in 1 8; do
        [ "$(XC_PAR_THREADS=$t "$W/gout" | tr '\n' ' ')" = "2 1999998 0 0 " ] || { echo "FAIL outline: the overlap program with $t threads: $(XC_PAR_THREADS=$t "$W/gout" | tr '\n' ' ')"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "--- outline: pass ---" || echo "--- outline: FAIL ---"
exit $fail
