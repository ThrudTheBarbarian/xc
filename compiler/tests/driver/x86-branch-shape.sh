#!/bin/bash
# x86-branch-shape.sh — an x86 conditional branch is one jump to its target,
# with the other edge falling through (2026-11-01).
#
# Each CondBranch was `jcc .Lf; jmp T; .Lf: jmp F` (a trampoline per branch),
# so the path into the next block took a branch either way. Now: a back edge
# with phi copies keeps them inline before its jmp (a loop latch), otherwise
# the edge to the next block falls through and the other gets the one jump (a
# stub after the function holds a jumped edge's copies). sieve on an Intel
# i5-14500: 1.33 -> 1.14 s, against the 0.9 build.
#
# Checked for tests/fixtures/sieve_shape.xc at each SIMD level: the two
# compilers' assembly is the same, has no `.Lf_` trampoline, and the program
# built for this host prints the right answer.
#
#   bash tests/driver/x86-branch-shape.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/sieve_shape.xc
fail=0
for l in base avx2 avx512 auto; do
    "$REF" -q -H . -A x86_64 -O3 -msimd=$l -S -o "$W/r.s" "$F" > "$W/e" 2>&1 || { echo "FAIL x86-branch-shape: $l: $(basename "$REF") does not build it"; fail=1; continue; }
    "$XC" -q -H . -A x86_64 -O3 -msimd=$l -S -o "$W/x.s" "$F" > "$W/e" 2>&1 || { echo "FAIL x86-branch-shape: $l: $(basename "$XC") does not build it"; fail=1; continue; }
    cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL x86-branch-shape: $l: the two compilers' assembly differs"; fail=1; }
    n=$(grep -c '^\.Lf_' "$W/x.s")
    [ "$n" = 0 ] || { echo "FAIL x86-branch-shape: $l: $n .Lf_ trampolines"; fail=1; }
done
"$XC" -q -H . -O3 -o "$W/p" "$F" > "$W/e" 2>&1 || { echo "FAIL x86-branch-shape: no host build"; exit 1; }
got=$("$W/p")
[ "$got" = "$(cat tests/fixtures/sieve_shape.expected.out)" ] || { echo "FAIL x86-branch-shape: prints '$got'"; fail=1; }
[ $fail = 0 ] && echo "x86-branch-shape: ok"
exit $fail
