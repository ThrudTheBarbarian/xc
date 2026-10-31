#!/bin/bash
# dead-store.sh — a store to a local that a later store overwrites, with
# nothing reading memory between, is dropped (2026-10-25). A struct local
# with no initialiser is zero-filled (owner, 2026-10-24) and then usually
# assigned field by field at once: struct_copy's loop stored each field twice
# and ran 1.5x slower than 0.86 (1.30 s against 0.86 s on the Linux host).
# struct_copy's loop body stores nothing (2026-10-31: p's slot is
# write-only once bump() is inlined, write-only-local.sh), the two compilers
# agree, and dead_store.xc (the stores that must stay: a read between, a
# call, a store through a pointer, a variable index) gives its answer.
#
#   bash tests/driver/dead-store.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
SRC=../benchmark/src/struct_copy.xc
if [ -f "$SRC" ]; then
    "$XC" -q -O2 -I ../benchmark/src -H . --emit-ir-opt -o "$W/sc" "$SRC" 2> "$W/sc.ir"
    n=$(awk '/function main\(/,/^  }/' "$W/sc.ir" | sed -n '/bb_1_for_body:/,/CondBranch/p' | grep -c ' = Store ')
    [ "$n" = 0 ] || { echo "FAIL dead-store: struct_copy's loop stores $n times, want 0"; fail=1; }
fi
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    for o in O0 O2; do
        "$c" -q -$o -H . -o "$W/ds" tests/fixtures/dead_store.xc || { echo "FAIL dead-store: $c -$o does not build"; fail=1; continue; }
        got=$("$W/ds")
        [ "$got" = "$(cat tests/fixtures/dead_store.expected.out)" ] || { echo "FAIL dead-store: $c -$o gives '$got'"; fail=1; }
    done
done
[ $fail = 0 ] && echo "dead-store: ok"
exit $fail
