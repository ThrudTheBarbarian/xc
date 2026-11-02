#!/bin/bash
# x86-backedge-copy.sh — a vectorised loop's counter and its next value share a
# register, so the loop closes with one conditional branch (2026-11-02).
#
# The homing allocator paired a phi with its incoming values, but tried them
# in operand order and did not hold the register it chose for a partner still
# to come: array_map's counter took the entry value's register, values
# allocated in between filled the one `i + 64` had, and every trip ended
# `mov r13d, esi; jmp top` after the exit test. Now a phi tries its back
# edge's value first, and a register taken for a waiting partner is kept for
# it unless nothing else fits.
#
# Checked, for tests/fixtures/backedge_copy.xc at x86-64 -O3: no unrolled
# vector loop (a `_vu0` block) is closed by an unconditional jump back to
# itself, in any SIMD clone; the two compilers' assembly is the same; and
# the program built for this host prints the right sum.
#
#   bash tests/driver/x86-backedge-copy.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/backedge_copy.xc
fail=0
"$REF" -q -H . -A x86_64 -O3 -S -o "$W/ref.s" "$F" || { echo "FAIL: $REF did not build $F"; exit 1; }
"$XC" -q -H . -A x86_64 -O3 -S -o "$W/xc.s" "$F" || { echo "FAIL: $XC did not build $F"; exit 1; }
n=$(grep -c '_for_body_vu0:$' "$W/ref.s")
back=$(grep -oE '_for_body_vu0:$' "$W/ref.s" >/dev/null; awk '/_for_body_vu0:$/{l=$0; sub(/:$/, "", l); labs[l]=1} /^\tjmp\t/{t=$2; if (t in labs) c++} END{print c+0}' "$W/ref.s")
if [ "$n" -eq 0 ]; then
    echo "FAIL: no unrolled vector loop in the x86-64 assembly"; fail=1
elif [ "$back" -ne 0 ]; then
    echo "FAIL: $back of $n unrolled vector loops close with jmp (a back-edge copy)"; fail=1
else
    echo "ok: $n unrolled vector loops, each closed by a conditional branch"
fi
cmp -s "$W/ref.s" "$W/xc.s" && echo "ok: the two compilers' assembly is the same" \
    || { echo "FAIL: the two compilers' x86-64 assembly differs"; fail=1; }
"$XC" -q -H . -O3 -o "$W/run" "$F" && out=$("$W/run") || out="(no run)"
want=$(cat tests/fixtures/backedge_copy.expected.out)
[ "$out" = "$want" ] && echo "ok: prints $out" || { echo "FAIL: printed '$out', want '$want'"; fail=1; }
[ $fail -eq 0 ] && echo "x86-backedge-copy: ok"
exit $fail
