#!/bin/bash
# cguard-got.sh — on macOS the xcc half of a C file that links libRuntime
# reads the stack guard through the GOT. The guard is the library's, so the
# image does not define it, and the link leaves an @PAGE reference to an
# import unpatched: each canary would read the word at the start of its own
# code page, and a function whose check lands in another page than its store
# stopped with "stack smashing detected".
#
# The object's relocations against ___xt_stack_guard are GOT loads (none is
# a page or page-offset reference), and the program prints clang's answer.
#
# Needs the arm64-macos libRuntime built in this tree; says so and passes
# when it is not (the gate builds it first). macOS only.
#
#   bash tests/driver/cguard-got.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "cguard-got: skipped (macOS arm64 only)"; exit 0; }
LIB=support/runtime-lib/arm64-macos/libRuntime.dylib
[ -f "$LIB" ] || { echo "cguard-got: skipped (no $LIB: make runtime-libs)"; exit 0; }
clang --version > /dev/null 2>&1 || { echo "cguard-got: skipped (no clang)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
# A function with a local array (so it has a canary) that xcc compiles.
cat > "$W/g.c" <<'C'
#include <stdio.h>
__attribute__((noinline)) static long fill(int n)
{
    long a[64];
    for (int i = 0; i < 64; i++) a[i] = (long)i * n;
    long s = 0;
    for (int i = 0; i < 64; i++) s += a[(i * 7) & 63];
    return s;
}
int main(void)
{
    long t = 0;
    for (int k = 1; k <= 100; k++) t += fill(k);
    printf("%ld\n", t);
    return 0;
}
C
"$XC" -q -O2 -H . -c -o "$W/g.o" "$W/g.c" > "$W/b" 2>&1 || { echo "FAIL cguard-got: -c does not build"; head -5 "$W/b"; exit 1; }
rel=$(otool -rv "$W/g.o" | grep '___xt_stack_guard')
if [ -z "$rel" ]; then
    echo "FAIL cguard-got: the object reads no stack guard (a canary was expected)"; fail=1
elif echo "$rel" | grep -qE 'PAGE21|PAGOF12'; then
    echo "FAIL cguard-got: the guard is read through @PAGE ($(echo "$rel" | grep -cE 'PAGE21|PAGOF12') relocations), e.g.:"; echo "$rel" | head -2 | sed 's/^/    /'; fail=1
else
    echo "  ok: the guard is read through the GOT"
fi
clang -O2 -w -o "$W/ref" "$W/g.c" && want=$("$W/ref")
"$XC" -q -O2 -H . -o "$W/g" "$W/g.c" > "$W/b" 2>&1 || { echo "FAIL cguard-got: does not build"; head -5 "$W/b"; exit 1; }
otool -L "$W/g" | grep -q libRuntime || { echo "FAIL cguard-got: the program does not link libRuntime"; fail=1; }
got=$("$W/g" 2>&1)
[ "$got" = "$want" ] && echo "  ok: the program gives clang's answer ($got)" \
    || { echo "FAIL cguard-got: the program gives '$got', clang's '$want'"; fail=1; }
[ $fail = 0 ] && echo "--- cguard-got: pass ---" || echo "--- cguard-got: FAIL ---"
exit $fail
