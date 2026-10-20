#!/bin/bash
# cpath.sh — the C path (experimental; cpp-front-end.md, "The C path"):
# `xcc prog.c` has clang compile the C to LLVM IR, reads that, and builds what
# it reads with xcc's own optimiser and back end; clang compiles the rest (the
# globals, and a function using what is not read: mix.c's switch, function
# pointer and array local), and the two objects are linked. Each program gives the output clang's
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
cat > "$W/st.c" <<'C'
#include <stdio.h>
#define N 100000
struct P { double x, y; int k; };
struct P pts[N];
double len2(struct P *p) { return p->x * p->x + p->y * p->y; }
int main(void)
{
    for (int i = 0; i < N; i++) {
        pts[i].x = i * 0.5;
        pts[i].y = 1.0;
        pts[i].k = i & 7;
    }
    struct P q;
    q.x = 3.0; q.y = 4.0; q.k = 1;
    double s = 0;
    long t = 0;
    for (int i = 0; i < N; i++) {
        s += len2(&pts[i]);
        t += pts[i].k;
    }
    printf("%.1f %ld %.1f\n", s, t, len2(&q));
    return 0;
}
C
cat > "$W/mix.c" <<'C'
#include <stdio.h>
#include <string.h>
#define N 1000000
int table[N];
int scale_by = 3;
static double offset = 0.25;
static const char *names[] = { "zero", "one", "two" };
static int classify(int v)
{
    switch (v % 3) {
    case 0: return 10;
    case 1: return 20;
    default: return 30;
    }
}
typedef int (*op)(int);
static int twice(int v) { return 2 * v; }
int apply(op f, int v) { return f(v); }
int main(void)
{
    for (int i = 0; i < N; i++)
        table[i] = i * scale_by;
    long s = 0;
    for (int i = 0; i < N; i++)
        s += table[i];
    char buf[32];
    strcpy(buf, names[2]);
    printf("%ld %d %d %.2f %s\n", s, classify(7), apply(twice, 21), offset, buf);
    return 0;
}
C
for p in scale t1 saxpy st mix; do
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
# --par-auto on a C file is the IR outliner (there is no parser scan for C),
# and -I / -D reach clang.
mkdir -p "$W/inc"
printf '#define SCALE_K 4\n' > "$W/inc/k.h"
cat > "$W/defs.c" <<'C'
#include <stdio.h>
#include "k.h"
#ifndef N
#define N 10
#endif
int a[N];
int main(void)
{
    for (int i = 0; i < N; i++)
        a[i] = i * SCALE_K;
    long s = 0;
    for (int i = 0; i < N; i++)
        s += a[i];
    printf("%ld\n", s);
    return 0;
}
C
"$XC" -q -O3 --par-auto -H . -I "$W/inc" -DN=1000000 -o "$W/defs" "$W/defs.c" > "$W/defs.b" 2>&1 || { echo "FAIL cpath: --par-auto with -I/-D does not build"; head -3 "$W/defs.b"; fail=1; }
if [ -x "$W/defs" ]; then
    [ "$("$W/defs")" = "1999998000000" ] || { echo "FAIL cpath: --par-auto -DN=1000000 gives $("$W/defs")"; fail=1; }
    XC_PAR_REPORT=1 "$W/defs" 2>&1 | grep -q 'items on the' || { echo "FAIL cpath: --par-auto made no block of a C loop"; fail=1; }
fi
# The IR other clangs write (XC_C_LL hands the reader a file): CRLF lines, as
# clang on Windows ends them (the reader once found no `}` and left every
# function after the first to clang, main included), and LLVM 23's `f0x`
# floats, a float's own bits (read as 0 once). This machine's clang writes
# neither, so the file is its IR rewritten into both.
cat > "$W/fl.c" <<'C'
#include <stdio.h>
float k(void) { return 0.3f; }
int main(void)
{
    float s = 0.0f;
    for (int i = 0; i < 100; i++)
        s += (float)i * 0.3f;
    printf("%d %d\n", (int)(s * 10.0f), (int)(k() * 1000.0f));
    return 0;
}
C
clang -O1 -Xclang -disable-llvm-passes -fno-discard-value-names -S -emit-llvm -o "$W/fl.ll" "$W/fl.c" 2>/dev/null
clang -O2 -w -o "$W/fl.ref" "$W/fl.c"
if grep -q 'float 0x3FD3333340000000' "$W/fl.ll"; then
    perl -pe 's/float 0x3FD3333340000000/float f0x3E99999A/g; s/\n/\r\n/' "$W/fl.ll" > "$W/fl.crlf.ll"
    XC_C_LL="$W/fl.crlf.ll" XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/fl" "$W/fl.c" > "$W/fl.b" 2>&1 \
        || { echo "FAIL cpath: CRLF/f0x IR does not build"; head -3 "$W/fl.b"; fail=1; }
    grep -q 'left to clang: @main' "$W/fl.b" && { echo "FAIL cpath: CRLF IR left main to clang"; fail=1; }
    [ -x "$W/fl" ] && [ "$("$W/fl")" = "$("$W/fl.ref")" ] \
        || { echo "FAIL cpath: CRLF/f0x IR gives '$("$W/fl" 2>&1)', clang '$("$W/fl.ref")'"; fail=1; }
else
    echo "FAIL cpath: clang wrote 0.3f in a form this test does not expect"; fail=1
fi
[ $fail = 0 ] && echo "--- cpath: pass ---" || echo "--- cpath: FAIL ---"
exit $fail
