#!/bin/bash
# cfuse.sh — adjacent C loops --par-style lifts, fused before the outliner
# (#147): tests/par/cfuse/fuse.c has a chain of elementwise loops that runs as
# one block, and pairs that stay apart (a sum of doubles, different ranges,
# a neighbour read, code between); two pointer arguments run as one block
# when their arrays do not overlap. -Wpar-auto says
# which (cfuse/fuse.expected); the program prints the same fused, apart
# (-fno-par-fuse) and serially (--par-style=cpu), on the CPU and the GPU.
#
#   bash tests/par/cfuse.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/cfuse/fuse.c
fail=0
"$XC" -q -O2 -H . -Wpar-auto -o "$W/f" "$F" > "$W/w" 2>&1 || { echo "FAIL cfuse: no build: $(head -c 300 "$W/w")"; exit 1; }
grep -E "run as one block|run apart" "$W/w" | sed 's/.*warning: //' > "$W/r"
diff "$W/r" tests/par/cfuse/fuse.expected > "$W/d" || { echo "FAIL cfuse: -Wpar-auto says otherwise:"; cat "$W/d"; fail=1; }
"$XC" -q -O2 -H . -fno-par-fuse -o "$W/n" "$F" > /dev/null 2>&1 || { echo "FAIL cfuse: no -fno-par-fuse build"; exit 1; }
"$XC" -q -O2 -H . --par-style=cpu -o "$W/s" "$F" > /dev/null 2>&1 || { echo "FAIL cfuse: no serial build"; exit 1; }
want=$("$W/s")
for m in cpu gpu; do
    for b in f n; do
        got=$( (cd "$W" && XC_PAR=$m "./$b") 2>/dev/null)
        [ "$got" = "$want" ] || { echo "FAIL cfuse ($b, $m): '$got', wanted '$want'"; fail=1; }
    done
done
[ $fail = 0 ] && echo "--- cfuse: pass ---"
exit $fail
