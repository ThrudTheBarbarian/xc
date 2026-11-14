#!/bin/bash
# carrayreduce.sh — a C loop that updates a global array through an index
# read from data (h[key[i]] += 1, a histogram) becomes a par block (#143):
# each chunk updates a private copy of the array, and the copies are folded
# into it when the block ends. So does an | update. A loop that also reads
# the array another way stays serial. Every build gives clang's answer, on
# one thread, on every thread and under auto. Skipped without clang.
# Self-hosted compiler only.
#
#   bash tests/par/carrayreduce.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- carrayreduce: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/h.c" <<'C'
#include <stdio.h>
#define N (1 << 22)
unsigned key[N];
unsigned hist[256];
unsigned char bits[64];
unsigned seen[16];
int main(void)
{
    for (unsigned i = 0; i < N; i++)
        key[i] = (i * 2654435761u) >> 24;
    for (unsigned i = 0; i < N; i++)
        hist[key[i]] += 1;
    for (unsigned i = 0; i < N; i++)
        bits[key[i] & 63] |= (unsigned char)(1u << (i & 7));
    for (unsigned i = 0; i < N; i++)
        seen[key[i] & 15] = seen[key[i] & 15] + seen[(key[i] + 1) & 15] + 1;
    unsigned long t = 0;
    for (int b = 0; b < 256; b++)
        t += (unsigned long)hist[b] * (unsigned long)(b + 1);
    unsigned long u = 0;
    for (int b = 0; b < 64; b++)
        u += (unsigned long)bits[b] * (unsigned long)(b + 1);
    printf("%lu %lu %u %u\n", t, u, hist[7], seen[3]);
    return 0;
}
C
clang -O2 -o "$W/h.ref" "$W/h.c" 2>/dev/null || { echo "FAIL carrayreduce: clang cannot build h.c"; exit 1; }
want=$("$W/h.ref")
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=auto -H . -o "$W/h" "$W/h.c" > "$W/h.b" 2>&1 \
    || { echo "FAIL carrayreduce: h.c does not build"; head -3 "$W/h.b"; exit 1; }
# The histogram (line 11) and the | update (line 13) are blocks; the loop that
# reads seen[] at another element (line 15) is not.
for l in 11 13; do
    grep -qE "^outline: main:$l: outlined, a block" "$W/h.b" \
        || { echo "FAIL carrayreduce: the update at line $l is not a block"; grep "main:$l:" "$W/h.b" | head -3; fail=1; }
done
grep -qE "^outline: main:15: outlined, a block" "$W/h.b" && { echo "FAIL carrayreduce: the loop reading seen[] another way became a block"; fail=1; }
for dev in cpu auto; do
    for th in 1 4 ""; do
        got=$(XC_PAR=$dev XC_PAR_THREADS=$th "$W/h")
        [ "$got" = "$want" ] || { echo "FAIL carrayreduce: XC_PAR=$dev XC_PAR_THREADS=$th gives $got, clang's $want"; fail=1; }
    done
done
# Repeated, as a race shows only now and then.
for r in 1 2 3 4 5; do
    got=$("$W/h")
    [ "$got" = "$want" ] || { echo "FAIL carrayreduce: run $r gives $got, clang's $want"; fail=1; break; }
done
[ $fail = 0 ] && echo "--- carrayreduce: pass ---" || echo "--- carrayreduce: FAIL ---"
exit $fail
