#!/bin/bash
# cwparauto.sh — -Wpar-auto on a C file says what was lifted and why not.
# The IR outliner, which lifts a C or C++ file's loops, gave its reasons only
# under XC_PAR_OUTLINE_TRACE. With -Wpar-auto it says, at each of the
# program's own loops, as xc's lowering does for xc: the loop became a 'par'
# block, or it runs serially, and the reason in words. Nothing without the
# flag.
#
#   bash tests/par/cwparauto.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/w.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char** argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 100000;
    float* a = malloc(n * sizeof(float));
    for (int i = 0; i < n; i++)
        a[i] = (float)(i % 7);
    float s = 0.0f;
    for (int i = 0; i < n; i++)
        s = s * 0.5f + a[i];
    printf("%f\n", s);
    return 0;
}
C
fail=0
"$XC" -q -O2 -Wpar-auto -o "$W/w" "$W/w.c" 2> "$W/on.txt" || { echo "  FAIL: build"; exit 1; }
"$XC" -q -O2 -o "$W/w" "$W/w.c" 2> "$W/off.txt" || { echo "  FAIL: build without -W"; exit 1; }
grep -q "w.c:7:.*warning: this loop became a 'par' block (--par-style)" "$W/on.txt" \
    && echo "  ok: the lifted loop is named" || { echo "  FAIL: no 'became a par block' for line 7"; fail=1; }
grep -q "w.c:10:.*warning: this loop runs serially, not as a 'par' block (--par-style): [a-z]" "$W/on.txt" \
    && echo "  ok: the serial loop is named, with a reason" || { echo "  FAIL: no 'runs serially' with a reason for line 10"; fail=1; }
grep -q "par-auto\|par' block" "$W/off.txt" && { echo "  FAIL: warnings without -Wpar-auto"; fail=1; } || echo "  ok: nothing without the flag"
[ $fail = 0 ] || sed 's/^/    /' "$W/on.txt"
[ $fail = 0 ] && echo "--- cwparauto: pass ---" || echo "--- cwparauto: FAIL ---"
exit $fail
