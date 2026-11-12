#!/bin/bash
# vecheader.sh — a reduction whose element pointer is computed in the loop's
# condition block from the counter (clang's `getelementptr p, i` there, live
# out to the remainder loop), as the C++ path hands it over (#157). The
# vectoriser left such a loop's vector accumulator with no update value and
# the variable-trip unroller then crashed on it; now the vectoriser leaves the
# loop scalar and the program gives clang's output at -O2 and -O3. Skipped
# without clang. Self-hosted compiler only.
#
#   bash tests/par/vecheader.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- vecheader: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
LL=$PWD/tests/par/c-ll/vec-header-red.ll
# The fixture is arm64 macOS IR; elsewhere, its target line is dropped so the
# host's clang takes it.
if [ "$PLAT" = osx ]; then cp "$LL" "$W/t.ll"; else grep -v '^target ' "$LL" > "$W/t.ll"; fi
printf 'int main(void) { return 0; }\n' > "$W/stub.c"
clang -O2 -w -o "$W/ref" "$W/t.ll" 2>/dev/null || { echo "--- vecheader: skipped (clang does not take the fixture here) ---"; exit 0; }
want=$("$W/ref")
for o in -O2 -O3; do
    XC_C_LL="$W/t.ll" "$XC" -q $o -H . -o "$W/t$o" "$W/stub.c" > "$W/b$o" 2>&1 \
        || { echo "FAIL vecheader: $o does not build (exit $?)"; tail -3 "$W/b$o"; fail=1; continue; }
    got=$("$W/t$o")
    [ "$got" = "$want" ] || { echo "FAIL vecheader: $o gives '$got', clang '$want'"; fail=1; }
done
[ $fail = 0 ] && echo "--- vecheader: pass ---" || echo "--- vecheader: FAIL ---"
exit $fail
