#!/bin/bash
# vec-phi-entry.sh — a vector phi whose entry value is still read (#220). The
# escape vectoriser runs `h = i; for (j < i) h = h * 31 + j; out[i] = h` four
# or more items at a time. h's vector phi starts from the vector of i values,
# which is also the inner loop's bound. Coalesced onto one register, every
# update of h moved the bound, and -O2 gave wrong answers on x86-64 and
# arm64. -O0 runs no vectoriser: -O2 must print the same.
#
#   bash tests/codegen/vec-phi-entry.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/vp.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#define N 3000
int main(void)
{
    unsigned* out = malloc(N * sizeof(unsigned));
    unsigned* out2 = malloc(N * sizeof(unsigned));
    for (int i = 0; i < N; i++) {
        unsigned h = (unsigned)i;
        for (int j = 0; j < i; j++)
            h = h * 31u + (unsigned)j;
        out[i] = h & 1023;
    }
    for (int i = 0; i < N; i++) {
        unsigned h = (unsigned)i ^ 12345u;
        for (int j = 0; j < i; j++)
            h = h * 31u + (unsigned)j;
        out2[i] = h & 1023;
    }
    unsigned long long s = 0, s2 = 0;
    for (int i = 0; i < N; i++) { s += out[i]; s2 += out2[i]; }
    printf("%llu %llu %u %u\n", s, s2, out[5], out[100]);
    return 0;
}
C
"$XC" -q -O0 --par-style=cpu -o "$W/v0" "$W/vp.c" || { echo "FAIL: -O0 build"; exit 1; }
"$XC" -q -O2 --par-style=cpu -o "$W/v2" "$W/vp.c" || { echo "FAIL: -O2 build"; exit 1; }
a=$("$W/v0"); b=$("$W/v2")
if [ -n "$a" ] && [ "$a" = "$b" ]; then
    echo "  ok: -O0 and -O2 agree ($a)"
    echo "--- vec-phi-entry: pass ---"
    exit 0
fi
echo "  FAIL: -O0 '$a' vs -O2 '$b'"
echo "--- vec-phi-entry: FAIL ---"
exit 1
