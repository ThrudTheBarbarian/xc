#!/bin/bash
# cpath.sh — the C path (experimental; cpp-front-end.md, "The C path"):
# `xcc prog.c` has clang compile the C to LLVM IR, reads that, and builds it
# with xcc's own optimiser and back end. Each program gives the output clang's
# own build gives; with the IR outliner on (XC_PAR_PROPOSE=outline) its loops
# become par blocks, and it still does, on the CPU and (on macOS) the GPU.
# Skipped where there is no clang. Self-hosted compiler only.
#
#   bash tests/par/cpath.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- cpath: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/scale.c" <<'C'
#include <stdio.h>
#define N 1000000
double a[N], b[N];
void scale(double *d, const double *s, double k, int n)
{
    for (int i = 0; i < n; i++)
        d[i] = k * s[i];
}
int main(void)
{
    for (int i = 0; i < N; i++)
        b[i] = i * 0.5;
    scale(a, b, 3.0, N);
    double t = 0;
    for (int i = 0; i < N; i++)
        t += a[i];
    printf("%.1f\n", t);
    return 0;
}
C
cat > "$W/t1.c" <<'C'
#include <stdio.h>
double g[4];
int add(int x, int y) { return x + y; }
int main(void)
{
    int s = 0;
    for (int i = 0; i < 10; i++)
        s += i;

    printf("%d %d %.2f %.2f\n", s, add(3, 4), 1.5, 2.25);
    return 0;
}
C
cat > "$W/saxpy.c" <<'C'
#include <stdio.h>
#define N 4000000
float x[N], y[N];
unsigned h[N];
void saxpy(float a, float *xs, float *ys, int n)
{
    for (int i = 0; i < n; i++)
        ys[i] = a * xs[i] + ys[i];
}
int main(void)
{
    for (int i = 0; i < N; i++) {
        x[i] = (float)(i % 1000) * 0.5f;
        y[i] = 1.0f;
    }
    saxpy(2.0f, x, y, N);
    long long sum = 0;
    for (int i = 0; i < N; i++)
        sum += (long long)y[i];
    for (int i = 0; i < N; i++)
        h[i] = (unsigned)i * 2654435761u;
    unsigned mix = 0;
    for (int i = 0; i < N; i++)
        mix ^= h[i];
    printf("%lld %u %.1f\n", sum, mix, y[N - 1]);
    return 0;
}
C
for p in scale t1 saxpy; do
    clang -O2 -o "$W/$p.ref" "$W/$p.c" 2>/dev/null || { echo "FAIL cpath: clang cannot build $p"; fail=1; continue; }
    want=$("$W/$p.ref")
    "$XC" -q -O2 -H . -o "$W/$p" "$W/$p.c" > "$W/$p.b" 2>&1 || { echo "FAIL cpath: $p does not build"; head -3 "$W/$p.b"; fail=1; continue; }
    [ "$("$W/$p")" = "$want" ] || { echo "FAIL cpath: $p gives $("$W/$p"), clang's $want"; fail=1; }
    XC_PAR_OUTLINE_TRACE=1 XC_PAR_PROPOSE=outline "$XC" -q -O3 -H . -o "$W/$p.par" "$W/$p.c" > "$W/$p.pb" 2>&1 || { echo "FAIL cpath: $p does not build with outlining"; head -3 "$W/$p.pb"; fail=1; continue; }
    for d in cpu gpu; do
        got=$(XC_PAR=$d "$W/$p.par")
        [ "$got" = "$want" ] || { echo "FAIL cpath: $p's blocks ($d) give $got, clang's $want"; fail=1; }
    done
done
# The loops that become blocks: scale's (two pointers, checked at the call)
# and main's fill; saxpy's five.
n=$(cat "$W/scale.pb" "$W/saxpy.pb" 2>/dev/null | grep -c ': outlined, a block')
[ "$n" -ge 7 ] || { echo "FAIL cpath: $n C loops became blocks, wanted 7"; fail=1; }
if [ "$(uname -s)" = Darwin ]; then
    XC_PAR=gpu XC_PAR_REPORT=1 "$W/saxpy.par" 2>&1 | grep -q 'items on the GPU' || { echo "FAIL cpath: no C loop ran on the GPU"; fail=1; }
fi
[ $fail = 0 ] && echo "--- cpath: pass ---" || echo "--- cpath: FAIL ---"
exit $fail
