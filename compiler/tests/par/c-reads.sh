#!/bin/bash
# c-reads.sh — what the C/C++ reader takes rather than leaving to clang
# (2026-11-22): local arrays (`alloca [256 x double]`, of arrays too, as one
# slot of their elements), llvm.memset / llvm.memcpy (the C library's), and
# calls through a pointer (a function pointer, a table of them as a C++
# vtable is) as CallIndirect. llvm.experimental.noalias.scope.decl, which
# clang's passes write in the C++ row, is a hint and skipped (the C++
# corpus's strings.cpp has one).
#
# tests/par/c-reads/reads.c: xcc builds it with no function left to clang,
# and it gives clang's output. Skipped without clang.
#
#   bash tests/par/c-reads.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then echo "--- c-reads: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-reads/reads.c
fail=0
clang -O2 -o "$W/ref" "$F" || { echo "FAIL c-reads: clang does not build it"; exit 1; }
want=$("$W/ref")
for O in -O0 -O2; do
    XC_C_TRACE=1 "$XC" -q $O -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL c-reads $O: does not build"; grep -v warning "$W/b" | head -3; fail=1; continue; }
    got=$("$W/x" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL c-reads $O: gives '$got', clang's '$want'"; fail=1; }
    if grep -q 'left to clang' "$W/b"; then
        echo "FAIL c-reads $O: functions left to clang:"; grep 'because of' "$W/b" | head -4; fail=1
    fi
done
[ $fail = 0 ] && echo "--- c-reads: pass ---" || echo "--- c-reads: FAIL ---"
exit $fail
