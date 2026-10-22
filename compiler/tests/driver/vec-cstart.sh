#!/bin/bash
# vec-cstart.sh — C loops whose start is not a literal (2026-10-22). C's `a[i]`
# with an unsigned i reads `zext i` into a 64-bit index; a literal start let
# mem2reg see i's range and index with i itself, which is the shape the
# vectoriser takes. A run-time start (argc - 1, a volatile) now gets the same
# from bounds-elide's interval analysis when i is proved inside [0, 2^31), and
# the loop vectorises. A loop whose range is not proved keeps the wide index
# and still gives the right answer. On a Mac the arm64 build's main is checked
# for vector instructions; elsewhere only the answers are.
#
#   bash tests/driver/vec-cstart.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "--- vec-cstart: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/a.c" <<'C'
#include <stdio.h>
#define SIZE (1 << 20)
unsigned xs[SIZE], ys[SIZE];
static volatile unsigned start_v;
int main(int argc, char **argv)
{
    for (unsigned i = 0; i < SIZE; i++) { xs[i] = i * 2654435761u; ys[i] = i ^ 0x5a5a; }
    unsigned total = 0;
    for (unsigned i = (unsigned)argc - 1; i < SIZE; i++) {
        unsigned v = 3u * xs[i] + ys[i];
        ys[i] = v;
        total = total + v;
    }
    unsigned s = start_v;
    for (unsigned i = s; i < SIZE; i++)
        total += xs[i] >> 3;
    printf("%u\n", total);
    return 0;
}
C
# Not proved: the bound comes from the command line, so i may pass 2^31.
cat > "$W/b.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
unsigned xs[4096];
int main(int argc, char **argv)
{
    for (unsigned i = 0; i < 4096; i++) xs[i] = i * 7u + 1u;
    unsigned n = argc > 1 ? (unsigned)atoi(argv[1]) : 4096u;
    unsigned total = 0;
    for (unsigned i = (unsigned)argc - 1; i < n; i++)
        total += xs[i];
    printf("%u\n", total);
    return 0;
}
C
for p in a b; do
    clang -O2 -o "$W/$p.ref" "$W/$p.c" 2> /dev/null || { echo "FAIL vec-cstart: clang does not build $p.c"; exit 1; }
    "$XC" -q -O2 -H . -o "$W/$p" "$W/$p.c" > "$W/$p.b" 2>&1 || { echo "FAIL vec-cstart: $p.c does not build"; head -3 "$W/$p.b"; fail=1; continue; }
    [ "$("$W/$p")" = "$("$W/$p.ref")" ] || { echo "FAIL vec-cstart: $p gives $("$W/$p"), clang $("$W/$p.ref")"; fail=1; }
done
if [ "$PLAT" = osx ] && command -v otool > /dev/null; then
    n=$(otool -tv "$W/a" | awk '/^_main:/{f=1;next} f&&/^_[A-Za-z_][A-Za-z0-9_$]*:$/{exit} f' | grep -cE '\.4s|ld1|st1|addv')
    [ "$n" -ge 12 ] || { echo "FAIL vec-cstart: the run-time-start loops are not vectorised ($n vector instructions in main)"; fail=1; }
fi
[ $fail = 0 ] && echo "--- vec-cstart: pass ---" || { echo "--- vec-cstart: FAIL ---"; exit 1; }
