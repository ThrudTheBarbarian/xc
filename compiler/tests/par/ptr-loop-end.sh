#!/bin/bash
# ptr-loop-end.sh — a pointer a C/C++ loop steps, used past the loop, is
# its value at the end (2026-11-26). The C/C++ path rewrites such a loop to
# count i and make each pointer element [i] in the body; a use past the exit
# is the pointer's last value. Only the exit block itself was renamed, so a
# use further on read element [n - 1]: std::vector's constructor from
# reverse iterators handed std::reverse an end one element short.
#
# tests/par/c-loop-exit/revcopy.cpp must give clang++'s output, serially and
# with --par-style=auto (cpu). Skipped without clang++.
#
#   bash tests/par/ptr-loop-end.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- ptr-loop-end: skipped (no clang++) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-loop-exit/revcopy.cpp
fail=0
clang++ -std=c++20 -O2 -o "$W/ref" "$F" || { echo "FAIL ptr-loop-end: clang++ does not build it"; exit 1; }
want=$("$W/ref")
for how in serial auto; do
    st=""; [ $how = auto ] && st="--par-style=auto"
    "$XC" -q -O3 $st -std=c++20 -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL ptr-loop-end ($how): does not build"; grep -v warning "$W/b" | head -3; fail=1; continue; }
    got=$(XC_PAR=cpu "$W/x" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL ptr-loop-end ($how): gives '$got', clang++'s '$want'"; fail=1; }
done
[ $fail = 0 ] && echo "--- ptr-loop-end: pass ---" || echo "--- ptr-loop-end: FAIL ---"
exit $fail
