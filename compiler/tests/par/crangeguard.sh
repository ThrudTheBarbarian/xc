#!/bin/bash
# crangeguard.sh — C loops whose arrays the call site checks by range (#219).
# A lifted loop that writes out[i] and reads a[j] for j < i (a triangular
# nest) needs an overlap check. The outliner bounds j (an inner loop's
# counter up to i) and compares the byte ranges at the call site; the run's
# own check sizes the arrays with Par.spanOf, which knows a C program's
# malloc blocks of 64 KB and more (the runtime allocates them, #235). Apart
# arrays run as a block and give the serial answer. An `out` that lies inside
# `a` runs serially, with the same answer.
#
#   bash tests/par/crangeguard.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
for shape in apart inside; do
cat > "$W/$shape.c" <<C
#include <stdio.h>
#include <stdlib.h>
#define N 20000
int main(void)
{
    float* a = malloc(2 * N * sizeof(float));
    float* out = $( [ $shape = apart ] && echo 'malloc(N * sizeof(float))' || echo 'a + N / 2' );
    for (int i = 0; i < 2 * N; i++) a[i] = (float)(i % 97) * 0.01f;
    for (int i = 0; i < N; i++) {
        unsigned h = (unsigned)i;
        for (int j = 0; j < i; j++)
            h = h * 31u + (unsigned)(a[j] * 100.0f);
        out[i] = (float)(h & 1023);
    }
    double s = 0; for (int i = 0; i < N; i++) s += out[i];
    printf("%.0f\n", s);
    return 0;
}
C
"$XC" -q -O2 -o "$W/$shape" "$W/$shape.c" || { echo "  FAIL: $shape: build"; fail=1; continue; }
"$XC" -q -O2 --par-style=cpu -o "$W/$shape.ser" "$W/$shape.c" || { echo "  FAIL: $shape: serial build"; fail=1; continue; }
want=$("$W/$shape.ser")
XC_PAR=cpu XC_PAR_REPORT=1 "$W/$shape" > "$W/$shape.rep" 2>&1
got=$(grep -v '^par: ' "$W/$shape.rep" | tail -1)
if [ "$got" != "$want" ]; then echo "  FAIL: $shape: $got, serially $want"; fail=1; continue; fi
if [ $shape = apart ]; then
    grep -q "$shape.c:9: .* items on the CPU" "$W/$shape.rep" && echo "  ok: apart arrays run as a block ($got)" \
        || { echo "  FAIL: apart arrays did not run as a block"; sed 's/^/    /' "$W/$shape.rep"; fail=1; }
else
    grep -q "$shape.c:9: .*items on the CPU" "$W/$shape.rep" && { echo "  FAIL: overlapping arrays ran as a block"; fail=1; } \
        || echo "  ok: overlapping arrays run serially ($got)"
fi
done
[ $fail = 0 ] && echo "--- crangeguard: pass ---" || echo "--- crangeguard: FAIL ---"
exit $fail
