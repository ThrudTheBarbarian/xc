#!/bin/bash
# cwrites.sh — a block the outliner makes from a C loop says which captured
# arrays it writes whole (gpuWritesAllOwn), so a GPU run does not send their
# old contents. tests/par/cwrites/w.c: fill() overwrites out[i] (one array
# written whole), bump() reads a[i] before writing it (none). Read from the
# blocks' generated answers in the optimised IR; the program's output is the
# same as the loops run serially.
#
#   bash tests/par/cwrites.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=bin/$PLAT/xcc-xc
[ -x "$XC" ] || { echo "SKIP cwrites: $XC not built"; exit 0; }
command -v clang > /dev/null || { echo "SKIP cwrites: no clang"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
F=tests/par/cwrites/w.c
"$XC" -q -O2 --par-style=auto --emit-ir-opt -o "$W/w" "$F" 2> "$W/ir" || { echo "FAIL cwrites: no build: $(grep -m3 error "$W/ir")"; exit 1; }
"$XC" -q -O2 --par-style=cpu -o "$W/s" "$F" > /dev/null 2>&1 || { echo "FAIL cwrites: no serial build"; exit 1; }
# answers <line>: how many captures the block from w.c:<line> says it writes
# whole (-1: no such block). Its name is a string literal of the IR's bytes.
answers() {
    local lit=""
    lit=$(printf 'w.c:%s' "$1" | od -An -tx1 | tr -s ' \n' ' ' | sed 's/^ //; s/ $//' \
          | awk '{ for (i = 1; i <= NF; i++) printf "#$%s, ", toupper($i); printf "#$00]" }')
    awk -v lit="$lit" '
        index($0, "symbol ParOut$") && index($0, "$name: stringlit [" lit) { stem = $2; sub(/[$]name:$/, "", stem); target = stem }
        index($0, "function ") && index($0, "$gpuWritesAllOwn(") { cur = $2; sub(/[$]gpuWritesAllOwn[(].*/, "", cur); inf = 1; sel[cur] = 0; next }
        inf && index($0, "Select") { sel[cur]++ }
        inf && $0 == "  }" { inf = 0 }
        END { print (target in sel) ? sel[target] : -1 }' "$W/ir"
}
for k in "7 1" "8 0"; do
    set -- $k
    got=$(answers "$1")
    [ "$got" = "$2" ] || { echo "FAIL cwrites: the block at w.c:$1 says $got arrays written whole, want $2"; fail=1; }
done
for m in cpu gpu; do
    a=$(XC_PAR=$m "$W/w"); b=$("$W/s")
    [ -n "$a" ] && [ "$a" = "$b" ] || { echo "FAIL cwrites ($m): '$a', serial '$b'"; fail=1; }
done
[ $fail = 0 ] && echo "--- cwrites: pass ---"
exit $fail
