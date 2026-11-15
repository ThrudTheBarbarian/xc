#!/bin/bash
# c-alloca.sh — a C function that allocates a run-time size on the stack
# (__builtin_alloca(n), `alloca i8, i64 %n`): xcc leaves it to clang rather
# than give the buffer one fixed word, which the loop overwrote (stack
# smashing detected). tests/par/c-alloca/sumto.c gives clang's answer, and
# the trace says why sumto is clang's. Skipped without clang.
#
#   bash tests/par/c-alloca.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then echo "--- c-alloca: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-alloca/sumto.c
fail=0
clang -O2 -o "$W/ref" "$F" || { echo "FAIL c-alloca: clang does not build it"; exit 1; }
want=$("$W/ref")
XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL c-alloca: does not build"; grep -v warning "$W/b" | head -3; exit 1; }
got=$("$W/x" 2>&1)
[ "$got" = "$want" ] || { echo "FAIL c-alloca: gives '$got', clang's '$want'"; fail=1; }
grep -q 'an alloca of more than one element' "$W/b" || { echo "FAIL c-alloca: sumto was not left to clang for its alloca"; grep -i 'sumto' "$W/b" | head -3; fail=1; }
[ $fail = 0 ] && echo "--- c-alloca: pass ---" || echo "--- c-alloca: FAIL ---"
exit $fail
