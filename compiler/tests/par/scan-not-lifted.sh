#!/bin/bash
# scan-not-lifted.sh — a running value read inside a loop is no reduction: a
# prefix sum (`s += a[i]; b[i] = s`), over global arrays and over malloc'd
# ones, is not made a par block (the outliner says so), and gives clang's
# output on the CPU, the GPU and auto. 1.0 lifted it and every chunk started
# its sum from zero. Skipped without clang. Self-hosted compiler only.
#
#   bash tests/par/scan-not-lifted.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- scan-not-lifted: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/g.c" <<'C'
#include <stdio.h>
#define N (1 << 20)
int a[N], b[N];
int main(void)
{
    for (long i = 0; i < N; i++) a[i] = (int)(i % 7) - 3;
    int s = 0;
    for (long i = 0; i < N; i++) { s += a[i]; b[i] = s; }
    long t = 0;
    for (long i = 0; i < N; i++) t += b[i];
    printf("%ld %d\n", t, b[N - 1]);
    return 0;
}
C
cat > "$W/h.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void scan(const int *in, int *out, long n)
{
    int s = 0;
    for (long i = 0; i < n; i++) { s += in[i]; out[i] = s; }
}
int main(void)
{
    long n = 1 << 20;
    int *a = malloc(n * 4), *b = malloc(n * 4);
    for (long i = 0; i < n; i++) a[i] = (int)(i % 7) - 3;
    scan(a, b, n);
    long t = 0;
    for (long i = 0; i < n; i++) t += b[i];
    printf("%ld %d\n", t, b[n - 1]);
    return 0;
}
C
for p in g h; do
    clang -O2 -w -o "$W/$p.ref" "$W/$p.c" || { echo "FAIL scan-not-lifted: clang cannot build $p.c"; fail=1; continue; }
    want=$("$W/$p.ref")
    XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -H . -o "$W/$p" "$W/$p.c" > "$W/$p.b" 2>&1 \
        || { echo "FAIL scan-not-lifted: $p.c does not build"; head -3 "$W/$p.b"; fail=1; continue; }
    grep -q 'not a block: an accumulator read in the loop' "$W/$p.b" \
        || { echo "FAIL scan-not-lifted: $p.c's prefix sum was not refused:"; grep '^outline' "$W/$p.b" | head -4; fail=1; }
    for m in cpu gpu auto; do
        mkdir -p "$W/s.$p.$m"
        got=$(XC_PAR=$m XCC_SETTINGS_DIR="$W/s.$p.$m" "$W/$p")
        [ "$got" = "$want" ] || { echo "FAIL scan-not-lifted: $p.c ($m) gives '$got', clang '$want'"; fail=1; }
    done
done
[ $fail = 0 ] && echo "--- scan-not-lifted: pass ---" || echo "--- scan-not-lifted: FAIL ---"
exit $fail
