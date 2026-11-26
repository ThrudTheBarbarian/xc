#!/bin/bash
# c-reads.sh — what the C/C++ reader takes rather than leaving to clang
# (2026-11-22): local arrays (`alloca [256 x double]`, of arrays too, as one
# slot of their elements), llvm.memset / llvm.memcpy (the C library's),
# calls through a pointer (a function pointer, a table of them as a C++
# vtable is) as CallIndirect, and a large struct returned through a hidden
# pointer (`sret`: x8 on arm64; the first argument, and rax on return, on
# x86-64) (2026-11-23). llvm.experimental.noalias.scope.decl, which
# clang's passes write in the C++ row, is a hint and skipped (the C++
# corpus's strings.cpp has one).
#
# tests/par/c-reads/reads.c: xcc builds it with no function left to clang,
# and it gives clang's output. sext.c, read from clang's optimised IR, has a
# `sext i1` (all ones when true). switch.c's switches are read as chains of
# compares (2026-11-26). Skipped without clang.
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
# A phi of constant expressions with commas of their own (the vtable
# address of one of two thrown types): read, nothing left to clang.
V=tests/par/c-reads/vtphi.cpp
if clang++ --version >/dev/null 2>&1; then
    clang++ -O2 -o "$W/vref" "$V" || { echo "FAIL c-reads: clang++ does not build vtphi.cpp"; exit 1; }
    XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/vx" "$V" > "$W/vb" 2>&1 || { echo "FAIL c-reads: vtphi.cpp does not build"; grep -v warning "$W/vb" | head -3; fail=1; }
    [ -x "$W/vx" ] && { [ "$("$W/vx")" = "$("$W/vref")" ] || { echo "FAIL c-reads: vtphi.cpp gives '$("$W/vx")', clang++'s '$("$W/vref")'"; fail=1; }; }
    grep -q 'left to clang' "$W/vb" && { echo "FAIL c-reads: vtphi.cpp left to clang:"; grep 'because of' "$W/vb" | head -2; fail=1; }
fi
# sext.c through clang's optimised IR (XC_C_LL), where `x ? -1 : 0` is
# `sext i1`: all ones, not 1.
G=tests/par/c-reads/sext.c
clang -O2 -o "$W/sref" "$G" && clang -O1 -S -emit-llvm -fno-discard-value-names -o "$W/sext.ll" "$G" \
    || { echo "FAIL c-reads: clang does not build sext.c"; exit 1; }
grep -q 'sext i1' "$W/sext.ll" || { echo "FAIL c-reads: clang's IR for sext.c has no sext i1"; fail=1; }
XC_C_LL="$W/sext.ll" XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/sx" "$G" > "$W/sb" 2>&1 || { echo "FAIL c-reads: sext.c does not build"; head -3 "$W/sb"; fail=1; }
[ -x "$W/sx" ] && { [ "$("$W/sx")" = "$("$W/sref")" ] || { echo "FAIL c-reads: sext.c gives '$("$W/sx")', clang's '$("$W/sref")'"; fail=1; }; }
grep -q 'left to clang' "$W/sb" && { echo "FAIL c-reads: sext.c left to clang:"; grep 'because of' "$W/sb" | head -2; fail=1; }
# switch.c, from the read build and from clang's optimised IR, where a
# case goes straight to a join block whose phi names the switch's block.
H=tests/par/c-reads/switch.c
clang -O2 -o "$W/wref" "$H" && clang -O1 -S -emit-llvm -fno-discard-value-names -o "$W/switch.ll" "$H" \
    || { echo "FAIL c-reads: clang does not build switch.c"; exit 1; }
grep -q 'switch i32' "$W/switch.ll" && grep -q '= phi' "$W/switch.ll" || { echo "FAIL c-reads: clang's IR for switch.c has no switch with a phi"; fail=1; }
for how in read ll; do
    if [ $how = ll ]; then env XC_C_LL="$W/switch.ll" XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/w" "$H" > "$W/wb" 2>&1
    else XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/w" "$H" > "$W/wb" 2>&1; fi \
        || { echo "FAIL c-reads: switch.c ($how) does not build"; grep -v warning "$W/wb" | head -3; fail=1; continue; }
    [ "$("$W/w")" = "$("$W/wref")" ] || { echo "FAIL c-reads: switch.c ($how) gives '$("$W/w")', clang's '$("$W/wref")'"; fail=1; }
    grep -q 'left to clang' "$W/wb" && { echo "FAIL c-reads: switch.c ($how) left to clang:"; grep 'because of' "$W/wb" | head -2; fail=1; }
done
[ $fail = 0 ] && echo "--- c-reads: pass ---" || echo "--- c-reads: FAIL ---"
exit $fail
