#!/bin/bash
# auto-trace.sh — XC_PAR_AUTO_TRACE=1 over the par_auto_* fixtures gives the
# expected list (tests/par/auto-trace.expected): one line for each loop
# --par-style=auto looks at, with its verdict, the rule that decided it, the
# loop's form, and for a block its name, reductions, grid rank and ParImpl
# number. A change to which loops become blocks, or to how they are numbered,
# shows here as a difference.
#
# The trace must not change the output: each fixture's assembly is compared
# with the trace on and off.
#
#   bash tests/par/auto-trace.sh                   # bin/<plat>/xcc-xc
#   XC=path/to/xcc bash tests/par/auto-trace.sh
#   UPDATE=1 bash tests/par/auto-trace.sh          # rewrite the expected list
#
# Run from compiler/ or anywhere. x86-64 is the target on every host, since
# an Apple target built on Linux keeps its loops as loops.
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 2
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
EXP=tests/par/auto-trace.expected
[ -x "$XC" ] || { echo "auto-trace: no compiler at $XC"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/auto-trace.XXXXXX")
trap 'rm -rf "${W:?}"' EXIT

fail=0
: > "$W/got"
for src in tests/fixtures/par_auto_*.xc; do
    name=$(basename "$src" .xc)
    if ! XC_PAR_AUTO_TRACE=1 "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.on.s" "$src" > "$W/$name.err" 2>&1; then
        echo "FAIL $name: does not build"; sed 's/^/    /' "$W/$name.err" | head -5
        fail=1; continue
    fi
    grep '^par-auto-trace: ' "$W/$name.err" >> "$W/got"
    "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.off.s" "$src" > /dev/null 2>&1
    cmp -s "$W/$name.on.s" "$W/$name.off.s" || { echo "FAIL $name: the trace changed the assembly"; fail=1; }
done
if [ "${UPDATE:-0}" = 1 ]; then
    cp "$W/got" "$EXP"
    echo "auto-trace: wrote $EXP ($(wc -l < "$EXP") lines)"
elif ! diff -u "$EXP" "$W/got" > "$W/diff"; then
    echo "FAIL auto-trace: the trace differs from $EXP:"; head -40 "$W/diff"
    fail=1
fi
echo "--- par auto-trace: $(wc -l < "$W/got") loops, $(grep -c ' lifted ' "$W/got") lifted ---"
[ $fail = 0 ]
