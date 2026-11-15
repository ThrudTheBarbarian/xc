#!/bin/bash
# calias.sh — one array passed twice to a lifted C loop, written through one
# pointer and read back through the other at the same element (#264). The call
# site and the run let it stay a block, since each item touches its own
# element. On the CPU's threads that holds; a GPU binds the two pointers as two
# buffers, and the read saw the value from before the run. It now runs on the
# CPU, with the serial answer, wherever it is sent; the call with two arrays
# still runs as a block.
#
#   bash tests/par/calias.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
fail=0
cat > "$W/a.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
__attribute__((noinline)) static void mask(unsigned char* a, const unsigned char* b, unsigned char* c, long n)
{
    for (long i = 0; i < n; i++) {
        a[i] = (unsigned char)(a[i] & 0x0f);
        c[i] = b[i];
    }
}
int main(int argc, char** argv)
{
    long n = 1 << 20;
    unsigned char* p = malloc(n);
    unsigned char* q = malloc(n);
    unsigned char* r = malloc(n);
    for (long i = 0; i < n; i++) p[i] = (unsigned char)(i * 7 + (i >> 9));
    for (long i = 0; i < n; i++) r[i] = (unsigned char)(i * 5);
    mask(p, p, q, n);
    unsigned s = 0;
    for (long i = 0; i < n; i++) s += q[i];
    mask(r, p, q, n);
    unsigned t = 0;
    for (long i = 0; i < n; i++) t += q[i] + r[i];
    printf("%u %u\n", s, t);
    return 0;
}
C
"$XC" -q -O3 -o "$W/a" "$W/a.c" || { echo "FAIL calias: does not build"; exit 1; }
"$XC" -q -O3 --par-style=cpu -o "$W/a.ser" "$W/a.c" || { echo "FAIL calias: serial build"; exit 1; }
want=$("$W/a.ser")
for d in cpu gpu; do
    XC_PAR=$d XC_PAR_REPORT=1 "$W/a" > "$W/r.$d" 2>&1
    got=$(grep -v '^par: ' "$W/r.$d" | tail -1)
    [ "$got" = "$want" ] || { echo "FAIL calias: on $d gives $got, serially $want"; fail=1; }
done
# macOS sizes the malloc blocks, so the call with two arrays runs as a block
# there (Linux: serial until #235).
if [ "$PLAT" = osx ]; then
    grep -q 'a.c:5: one array is passed twice and written, so it runs on the CPU' "$W/r.gpu" \
        || { echo "FAIL calias: the call with one array twice did not keep to the CPU"; sed 's/^/    /' "$W/r.gpu"; fail=1; }
    [ "$(grep -c 'a.c:5: .*items on the' "$W/r.gpu")" -ge 1 ] \
        || { echo "FAIL calias: the call with two arrays did not run as a block"; sed 's/^/    /' "$W/r.gpu"; fail=1; }
fi
[ $fail = 0 ] && echo "--- calias: pass ---" || echo "--- calias: FAIL ---"
exit $fail
