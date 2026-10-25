#!/bin/bash
# coutline-vec.sh — a C loop outlined into a par block keeps the vector code
# of its plain build (2026-10-25): the block's loop runs over a chunk whose
# start and end come from the record, so nothing bounded the iv, `a[zext i]`
# stayed 64-bit and the escape-time vectoriser refused the loop. C nbody's
# block ran 95 ms on one thread against the plain build's 6.0. The outliner
# clamps the chunk's end to the loop's constant bound (min(hi, N), free at
# run time) and bounds-elide reads `i <u min(hi, N)` as `i < N`, so the
# subscripts narrow and the block vectorises: 32 threads 6.4 -> 0.82 ms on a
# Zen 5 (GCC -O3 -march=native -fopenmp 1.25).
#
#   bash tests/par/coutline-vec.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../benchmark/par/c/nbody.c
[ -f "$SRC" ] || { echo "coutline-vec: no benchmark/par/c/nbody.c, skipped"; exit 0; }
command -v clang > /dev/null || { echo "coutline-vec: no clang, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# x86-64, where it stayed scalar (the arm64 form vectorised already).
"$XC" -q -A x86_64 -O2 --par-auto --emit-ir-opt -H . -o "$W/nb" "$SRC" 2> "$W/ir" || { echo "FAIL coutline-vec: build"; tail -3 "$W/ir"; exit 1; }
n=$(awk '/function ParImpl\$o[0-9]*\$run(\$base)?\(/,/^  }/' "$W/ir" | grep -c 'Vec(')
[ "${n:-0}" -gt 0 ] || { echo "FAIL coutline-vec: the outlined block has no vector code"; fail=1; }
if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ]; then
    got=$(XC_PAR=cpu "$W/nb" | cut -d' ' -f1)
    [ "$got" = 42 ] || { echo "FAIL coutline-vec: nbody gives '$got', want 42"; fail=1; }
fi
[ $fail = 0 ] && echo "coutline-vec: ok"
exit $fail
