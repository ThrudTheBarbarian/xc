#!/bin/bash
# footprint.sh — a block over memory the runtime did not allocate (C's
# malloc) on the GPU. The runtime knows no span for such a pointer; the
# block's length for it is the loop's own footprint: the elements from
# k*lo + c0 to k*(hi-1) + c1 of a base touched only at [k*i + c] on every
# iteration. The GPU's buffer is copied in and back, so elements the loop
# does not write keep their values. A base touched only under a condition
# has no footprint (the loop may never reach the end), and its block stays
# on the CPU. Each program gives clang's output. macOS (Metal) only.
#
#   bash tests/par/footprint.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if [ "$(uname -s)" != Darwin ]; then
    echo "--- footprint: skipped (macOS only) ---"
    exit 0
fi
if ! clang --version >/dev/null 2>&1; then
    echo "--- footprint: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
# saxpy over malloc'd arrays.
cat > "$W/heap.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void saxpy(float a, const float *x, float *y, long n)
{
    for (long i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}
int main(void)
{
    long n = 1 << 22;
    float *x = malloc(n * sizeof(float)), *y = malloc(n * sizeof(float));
    for (long i = 0; i < n; i++) {
        x[i] = (float)(i % 1000);
        y[i] = 1.0f;
    }
    saxpy(2.0f, x, y, n);
    double t = 0;
    for (long i = 0; i < n; i++)
        t += y[i];
    printf("%.1f %.1f\n", y[12345], t);
    return 0;
}
C
# Every other element written (k = 2): the odd ones keep their values.
cat > "$W/stride.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void evens(float *y, const float *x, long half)
{
    for (long i = 0; i < half; i++)
        y[2 * i] = x[2 * i] * 3.0f;
}
int main(void)
{
    long n = 1 << 22;
    float *x = malloc(n * sizeof(float)), *y = malloc(n * sizeof(float));
    for (long i = 0; i < n; i++) {
        x[i] = (float)(i % 100);
        y[i] = -1.0f;
    }
    evens(y, x, n / 2);
    double t = 0;
    for (long i = 0; i < n; i++)
        t += y[i];
    printf("%.1f %.1f %.1f\n", y[10], y[11], t);
    return 0;
}
C
# A loop walking down (k = -1): y's lowest element is y[0].
cat > "$W/down.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#define N 4000000
static void reverse(float *y, const float *x)
{
    for (long i = 0; i < N; i++)
        y[N - 1 - i] = x[i] + 0.5f;
}
int main(void)
{
    float *x = malloc(N * sizeof(float)), *y = malloc(N * sizeof(float));
    for (long i = 0; i < N; i++)
        x[i] = (float)(i % 777);
    reverse(y, x);
    double t = 0;
    for (long i = 0; i < N; i++)
        t += y[i];
    printf("%.1f %.1f %.1f\n", y[0], y[N - 1], t);
    return 0;
}
C
# Touched only under a condition: x has m elements, the loop runs to n; no
# footprint, so the block stays on the CPU (and nothing reads past x).
cat > "$W/cond.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void head(float *y, const float *x, long n, long m)
{
    for (long i = 0; i < n; i++)
        if (i < m)
            y[i] = x[i] * 2.0f;
}
int main(void)
{
    long n = 1 << 22, m = 1000;
    float *x = malloc(m * sizeof(float)), *y = malloc(n * sizeof(float));
    for (long i = 0; i < m; i++)
        x[i] = (float)i;
    for (long i = 0; i < n; i++)
        y[i] = 0.0f;
    head(y, x, n, m);
    double t = 0;
    for (long i = 0; i < n; i++)
        t += y[i];
    printf("%.1f\n", t);
    return 0;
}
C
for p in heap stride down cond; do
    clang -O2 -o "$W/$p.ref" "$W/$p.c" 2>/dev/null || { echo "FAIL footprint: clang cannot build $p"; fail=1; continue; }
    want=$("$W/$p.ref")
    XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -H . -o "$W/$p" "$W/$p.c" > "$W/$p.b" 2>&1 || { echo "FAIL footprint: $p does not build"; head -3 "$W/$p.b"; fail=1; continue; }
    for d in cpu gpu; do
        got=$(XC_PAR=$d "$W/$p")
        [ "$got" = "$want" ] || { echo "FAIL footprint: $p ($d) gives $got, clang's $want"; fail=1; }
    done
    XC_PAR=gpu XC_PAR_REPORT=1 "$W/$p" > "$W/$p.r" 2>&1
done
for p in heap stride down; do
    grep -q "$p.c:[0-9]*: .* items on the GPU" "$W/$p.r" || { echo "FAIL footprint: $p's block did not run on the GPU"; grep -E 'outline|par:' "$W/$p.b" "$W/$p.r" | head -4; fail=1; }
done
grep -q "cond.c:[0-9]*: .* items on the GPU" "$W/cond.r" && { echo "FAIL footprint: cond's block (a conditional access) ran on the GPU"; fail=1; }
[ $fail = 0 ] && echo "--- footprint: pass ---" || echo "--- footprint: FAIL ---"
exit $fail
