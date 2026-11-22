#!/bin/bash
# c-no-runtime.sh — a C or C++ program built with --par-style=auto whose loops
# the outliner lifts none of carries none of the par runtime the C path lowers
# for the blocks (#278): no ParFnChunk, no Foundation classes, no heap
# (_xc_malloc), and it gives clang's answer. A program whose loop is lifted
# still has them, and its loop runs as a block. -c keeps the runtime: another
# object of the program may lift a loop.
#
# Skipped where there is no clang. Self-hosted compiler only.
#
#   bash tests/driver/c-no-runtime.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
clang --version > /dev/null 2>&1 || { echo "--- c-no-runtime: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
# The symbols the runtime brings: the par runtime's, Foundation's, the heap's.
RT='ParFnChunk|String\$|Array\$|_xc_malloc'
cat > "$W/hello.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
    char *p = malloc(1 << 20);
    p[0] = 'h';
    printf("%c: hello\n", p[0]);
    free(p);
    return 0;
}
C
cat > "$W/hello.cpp" <<'C'
#include <cstdio>
#include <string>
int main()
{
    std::string s("hello");
    s += ", C++";
    std::printf("%s\n", s.c_str());
    return 0;
}
C
cat > "$W/lift.c" <<'C'
#include <stdio.h>
#define N 1000000
double a[N], b[N];
int main(void)
{
    for (int i = 0; i < N; i++)
        b[i] = i * 0.5;
    for (int i = 0; i < N; i++)
        a[i] = 3.0 * b[i] + 1.0;
    double t = 0;
    for (int i = 0; i < N; i++)
        t += a[i];
    printf("%.1f\n", t);
    return 0;
}
C
# A program and the count of the runtime's symbols it defines or imports
# (from libRuntime, where the target has one).
# nm reads nothing from xcc's arm64-linux images (no .symtab, #562): there
# the dynamic symbols, read through the dynamic segment, are counted instead.
rtsyms() {
    local n; n=$(nm "$1" 2>/dev/null | grep -cE "$RT")
    if [ "$n" = 0 ] && command -v readelf > /dev/null 2>&1; then
        n=$(readelf --use-dynamic -s -W "$1" 2>/dev/null | grep -cE "$RT")
    fi
    echo "$n"
}
check() { # name, source, compiler, want-runtime (0/1)
    local n=$1 src=$2 cc=$3 want=$4
    $cc -O2 -w -o "$W/$n.ref" "$src" || { echo "FAIL c-no-runtime: clang does not build $n"; fail=1; return; }
    local ref; ref=$("$W/$n.ref")
    "$XC" -q -O2 -H . -o "$W/$n" "$src" > "$W/$n.b" 2>&1 || { echo "  FAIL: $n does not build"; head -5 "$W/$n.b"; fail=1; return; }
    local got; got=$(XC_PAR=cpu "$W/$n" 2>&1)
    [ "$got" = "$ref" ] || { echo "  FAIL: $n gives '$got', clang's '$ref'"; fail=1; return; }
    local k; k=$(rtsyms "$W/$n")
    if [ "$want" = 0 ] && [ "$k" != 0 ]; then
        echo "  FAIL: $n lifts no loop but defines $k runtime symbol(s), e.g.:"
        nm "$W/$n" | grep -E "$RT" | head -3 | sed 's/^/    /'; fail=1
    elif [ "$want" = 1 ] && [ "$k" = 0 ]; then
        echo "  FAIL: $n lifts a loop but has no runtime symbol"; fail=1
    else
        echo "  ok: $n gives clang's answer, $k runtime symbol(s)"
    fi
}
check hello "$W/hello.c" clang 0
clang++ --version > /dev/null 2>&1 && check hellocpp "$W/hello.cpp" clang++ 0
check lift "$W/lift.c" clang 1
# The lifted loop runs as a block.
runs=$(XC_PAR=cpu XC_PAR_REPORT=1 "$W/lift" 2>&1 | grep -c 'lift.c:[0-9]*: [0-9]* items on')
[ "$runs" -gt 0 ] && echo "  ok: lift.c's loops ran as blocks ($runs)" \
    || { echo "  FAIL: lift.c's loops never ran as blocks"; fail=1; }
# -c: the object keeps the runtime (another object may lift a loop).
if "$XC" -q -O2 -H . -c -o "$W/hello.o" "$W/hello.c" > "$W/o.b" 2>&1; then
    k=$(nm "$W/hello.o" 2>/dev/null | grep -cE 'ParFnChunk')
    [ "$k" != 0 ] && echo "  ok: -c keeps the runtime ($k ParFnChunk symbol(s))" \
        || { echo "  FAIL: -c dropped the runtime"; fail=1; }
else
    echo "  FAIL: -c of hello.c does not build"; head -5 "$W/o.b"; fail=1
fi
[ $fail = 0 ] && echo "--- c-no-runtime: pass ---" || echo "--- c-no-runtime: FAIL ---"
exit $fail
