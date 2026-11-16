#!/bin/bash
# cscan.sh — running totals in C and C++ loops become blocks (#272).
# `acc op= x[i]; out[i] = acc;` (or the store first) used to stay serial: the
# outliner took it for a reduction read in its loop. It now runs as a running
# total (ParFnChunk.runScanOn: slices from the identity, their totals folded
# in order, each slice's offset combined into what it stored). Each program
# prints a checksum of every element and the final total, compared with
# clang's (or clang++'s) build of the same source. Then the cases that stay
# serial: a short range, the output read in the loop, one array for both.
#
#   bash tests/par/cscan.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
CC=${CC:-clang}
CXX=${CXX:-clang++}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0

# case: name type n body [flags]
run_case() {
    local name=$1 ty=$2 n=$3 body=$4 flags=${5:-}
    cat > "$W/$name.c" <<C
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
    long n = $n;
    $ty* x = malloc((n + 1) * sizeof($ty));
    $ty* out = malloc((n + 1) * sizeof($ty));
    for (long i = 0; i < n; i++) x[i] = ($ty)((i * 2654435761u) % 97) - ($ty)40;
    $ty acc = ($ty)3;
    for (long i = 0; i < n; i++) { $body }
    unsigned long h = 1469598103934665603ul;
    for (long i = 0; i < n; i++) h = (h ^ (unsigned long)(long long)out[i]) * 1099511628211ul;
    printf("%lu %lld\n", h, (long long)acc);
    return 0;
}
C
    "$XC" -q -O2 $flags -o "$W/$name" "$W/$name.c" 2> "$W/$name.err" || { echo "  FAIL: $name: build"; sed 's/^/    /' "$W/$name.err" | head -4; fail=1; return; }
    "$CC" -O2 -w -o "$W/$name.ref" "$W/$name.c" || { echo "  FAIL: $name: clang"; fail=1; return; }
    local got want
    XC_PAR_REPORT=1 "$W/$name" > "$W/$name.rep" 2>&1
    got=$(grep -v '^par:' "$W/$name.rep" | tail -1); want=$("$W/$name.ref")
    if [ "$got" != "$want" ]; then echo "  FAIL: $name: $got, clang $want"; fail=1; return; fi
    local blocks; blocks=$(grep -c "$name.c:10: 256 items on the CPU" "$W/$name.rep")
    if [ "${6:-block}" = block ] && [ "$blocks" = 0 ]; then
        echo "  FAIL: $name: right answer but not run as a block"; sed 's/^/    /' "$W/$name.rep" | head -4; fail=1; return
    fi
    if [ "${6:-block}" = serial ] && [ "$blocks" != 0 ]; then
        echo "  FAIL: $name: ran as a block"; fail=1; return
    fi
    echo "  ok: $name"
}

run_case add_incl  long          3000017 "acc += x[i]; out[i] = acc;"
run_case add_excl  long          3000017 "out[i] = acc; acc += x[i];"
# The par runtime compiled into the program instead of libRuntime (#353).
run_case add_src   long          3000017 "acc += x[i]; out[i] = acc;" --no-runtime-lib
run_case add_int   int           1000003 "acc += x[i]; out[i] = acc;"
run_case add_uns   unsigned      1000003 "acc += x[i]; out[i] = acc;"
run_case or_incl   unsigned      1000003 "acc |= (unsigned)x[i] << (i % 20); out[i] = acc;"
run_case xor_excl  long          1000003 "out[i] = acc; acc ^= x[i] * i;"
run_case and_incl  "unsigned long" 1000003 "acc &= ~(1ul << (i % 60)); out[i] = acc;"
run_case min_incl  long          1000003 "long v = x[i] * (i % 7); if (v < acc) acc = v; out[i] = acc;"
run_case max_excl  int           1000003 "out[i] = acc; int v = x[i] * (int)(i % 7); if (v > acc) acc = v;"
run_case short_n   long          1000    "acc += x[i]; out[i] = acc;" "" serial
run_case two_outs  long          1000003 "acc += x[i]; out[i] = acc; x[i] = 0;" "" any

# The output read in the loop, or one array for both, stays serial with
# clang's answer.
cat > "$W/alias.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
__attribute__((noinline)) static long run(long* x, long* out, long n)
{
    long acc = 0;
    for (long i = 0; i < n; i++) { acc += x[i]; out[i] = acc; }
    return acc;
}
int main(void)
{
    long n = 1000003;
    long* a = malloc(n * sizeof(long));
    for (long i = 0; i < n; i++) a[i] = (i * 7) % 13 - 6;
    long t = run(a, a, n);
    unsigned long h = 0; for (long i = 0; i < n; i++) h = h * 31 + (unsigned long)a[i];
    printf("%lu %ld\n", h, t);
    return 0;
}
C
if "$XC" -q -O2 -o "$W/alias" "$W/alias.c" 2>/dev/null && "$CC" -O2 -o "$W/alias.ref" "$W/alias.c"; then
    [ "$("$W/alias")" = "$("$W/alias.ref")" ] && echo "  ok: one array for both gives clang's answer" || { echo "  FAIL: alias: $("$W/alias") vs $("$W/alias.ref")"; fail=1; }
else
    echo "  FAIL: alias: build"; fail=1
fi

# C++: the same loop through clang++'s IR.
cat > "$W/cpp.cpp" <<'C'
#include <cstdio>
#include <vector>
int main()
{
    long n = 2000003;
    std::vector<long> x(n), out(n);
    for (long i = 0; i < n; i++) x[i] = (i * 7) % 13 - 6;
    long acc = 5;
    for (long i = 0; i < n; i++) { acc += x[i]; out[i] = acc; }
    unsigned long h = 0; for (long i = 0; i < n; i++) h = h * 31 + (unsigned long)out[i];
    std::printf("%lu %ld\n", h, acc);
    return 0;
}
C
if "$XC" -q -O2 -o "$W/cpp" "$W/cpp.cpp" 2> "$W/cpp.err" && "$CXX" -O2 -o "$W/cpp.ref" "$W/cpp.cpp"; then
    [ "$("$W/cpp")" = "$("$W/cpp.ref")" ] && echo "  ok: C++ gives clang++'s answer" || { echo "  FAIL: C++: $("$W/cpp") vs $("$W/cpp.ref")"; fail=1; }
else
    echo "  FAIL: C++: build"; sed 's/^/    /' "$W/cpp.err" | head -3; fail=1
fi

[ $fail = 0 ] && echo "--- cscan: pass ---" || echo "--- cscan: FAIL ---"
exit $fail
