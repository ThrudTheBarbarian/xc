#!/bin/bash
# vec-escape.sh — escape-time loops in C (2026-10-22): a counted loop over
# pixels whose body runs an inner loop until a per-pixel test fails (mandelbrot)
# goes across pixels, a lane each, the inner loop under a lane mask. Shapes:
# run-time starts, a bound from a parameter, two tests, an integer escape loop,
# and loops that must stay scalar (a store or a call in the escape loop); each
# checked against clang. On a Mac, mandelbrot's arm64 code is checked for the
# float lane compare too.
#
#   bash tests/driver/vec-escape.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "--- vec-escape: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/s.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static volatile unsigned vstart;
float gx[1000];
unsigned cap = 77;
static unsigned mand(unsigned s, unsigned n, unsigned w, unsigned maxk)
{
    unsigned total = 0;
    for (unsigned i = s; i < 1003; i++) {
        float cx = (float)(i % 64) * (3.0f / 64.0f) - 2.0f;
        float cy = (float)(i / 64) * (3.0f / 16.0f) - 1.5f;
        float x = 0.0f, y = 0.0f;
        unsigned k = 0;
        while (k < 100 && x * x + y * y < 4.0f) {
            float xt = x * x - y * y + cx;
            y = 2.0f * x * y + cy;
            x = xt;
            k = k + 1;
        }
        total = total + k;
    }
    return total;
}
/* Two sums, a select, signed counters, a test that exits when TRUE, start 5. */
static int two(int s)
{
    int a = 0, b = 0;
    for (int i = s; i < 517; i++) {
        float c = (float)(i & 31) * 0.1f - 1.7f;
        float z = 0.0f;
        int k = 3;
        for (;;) {
            if (!(z * z < 9.0f)) break;
            if (k >= 60) break;
            z = z * z + c;
            k = k + 1;
        }
        a = a + k;
        b = b + (k > 20 ? 7 : i);
    }
    return a * 3 + b;
}
/* Must stay scalar: the escape loop stores. */
static unsigned stores(unsigned s)
{
    unsigned t = 0;
    for (unsigned i = s; i < 300; i++) {
        float x = (float)(i % 17) * 0.25f;
        unsigned k = 0;
        while (k < 40 && x < 30.0f) { x = x * 1.5f + 0.5f; gx[k] = x; k = k + 1; }
        t = t + k;
    }
    return t;
}
/* Must stay scalar: a call in the escape loop. */
static unsigned calls(unsigned s)
{
    unsigned t = 0;
    for (unsigned i = s; i < 300; i++) {
        unsigned k = 0;
        unsigned v = i;
        while (k < 30 && v != 1) { v = (v & 1) ? 3 * v + 1 : v / 2; if (v == 7) v = (unsigned)abs((int)v - 1); k = k + 1; }
        t = t + k;
    }
    return t;
}
/* An integer escape loop (Collatz steps, capped). */
static unsigned collatz(unsigned s)
{
    unsigned t = 0;
    for (unsigned i = s; i < 4099; i++) {
        unsigned v = i + 1;
        unsigned k = 0;
        while (k < 200 && v != 1) { v = (v & 1) != 0 ? v * 3 + 1 : v >> 1; k = k + 1; }
        t = t + k;
    }
    return t;
}
int main(int argc, char **argv)
{
    unsigned s = vstart;
    printf("mand %u %u %u\n", mand(s, 0, 0, 0), mand(s + 1, 0, 0, 0), mand(s + 3, 0, 0, 0));
    printf("two %d %d\n", two((int)s), two((int)s + 5));
    printf("stores %u calls %u\n", stores(s), calls(s));
    printf("collatz %u %u\n", collatz(s), collatz(s + 2));
    printf("argc %u\n", mand((unsigned)argc - 1, 0, 0, 0));
    return 0;
}
C
clang -O2 -o "$W/s.ref" "$W/s.c" 2> /dev/null || { echo "FAIL vec-escape: clang does not build it"; exit 1; }
"$W/s.ref" > "$W/exp"
for O in -O2 -O3; do
    "$XC" -q $O -H . -o "$W/s" "$W/s.c" > "$W/b" 2>&1 || { echo "FAIL vec-escape: $O does not build"; head -3 "$W/b"; fail=1; continue; }
    "$W/s" > "$W/out" 2>&1
    cmp -s "$W/out" "$W/exp" || { echo "FAIL vec-escape: $O answers differ from clang's"; diff "$W/out" "$W/exp" | head -6; fail=1; }
done
if [ "$PLAT" = osx ] && command -v otool > /dev/null; then
    "$XC" -q -O2 -H . -o "$W/s" "$W/s.c" > /dev/null 2>&1
    n=$(otool -tv "$W/s" | awk '/^_mand:/{f=1;next} f&&/^_[A-Za-z_][A-Za-z0-9_$]*:$/{exit} f' | grep -cE 'fcmgt|fcmge')
    [ "$n" -ge 1 ] || { echo "FAIL vec-escape: mand's escape loop is not vectorised"; fail=1; }
fi
[ $fail = 0 ] && echo "--- vec-escape: pass ---" || { echo "--- vec-escape: FAIL ---"; exit 1; }
