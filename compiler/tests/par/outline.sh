#!/bin/bash
# outline.sh — IR outlining (XC_PAR_PROPOSE=outline, stages 1-2 of moving
# --par-auto into the IR; cpp-front-end.md): every loop Propose would wrap
# becomes a function of its own, called once in its place, and the program
# gives the output it gives without. Self-hosted compiler only while it is
# experimental. The corpus check is the same comparison over every fixture.
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
XC_PAR_PROPOSE=outline "$XC" -q -O3 -H . "$W/o.xc" -o "$W/out" >"$W/b2" 2>&1 || { echo "FAIL outline: the outlined build"; head -3 "$W/b2"; fail=1; }
if [ $fail = 0 ]; then
    [ "$("$W/plain")" = "$("$W/out")" ] || { echo "FAIL outline: the outlined program's output differs: $("$W/out")"; fail=1; }
    [ "$("$W/plain")" = "999000 999 250" ] || { echo "FAIL outline: the plain program's output: $("$W/plain")"; fail=1; }
    # scale's loop, the fill, the sum (a returned result) and the max loop.
    n=$(nm "$W/out" 2>/dev/null | grep -c '_ParOut\$[0-9]*\$run$')
    [ "$n" -ge 4 ] || { echo "FAIL outline: $n loops outlined, wanted at least 4"; fail=1; }
fi
[ $fail = 0 ] && echo "--- outline: pass ---" || echo "--- outline: FAIL ---"
exit $fail
