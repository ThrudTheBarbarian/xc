#!/bin/bash
# vec-guard.sh — the overlap guard takes a std::vector's bytes from the
# vector (tests/par/c-vecguard/vecguard.cpp, #705): a gather from a 2 KB
# vector table runs as a block; the same through a struct shaped like a
# vector that is not one stays serial; the vector gather given one vector as
# both table and output stays serial. Every answer is clang++'s, on the CPU
# and the GPU. Skipped without clang++.
#
#   bash tests/par/vec-guard.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- vec-guard: skipped (no clang++) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
SRC=tests/par/c-vecguard/vecguard.cpp
fail=0
clang++ -O2 -std=c++17 -o "$W/ref" "$SRC" || { echo "FAIL vec-guard: clang++ does not build it"; exit 1; }
want=$("$W/ref")
"$XC" -q -O3 -std=c++17 -H . -o "$W/x" "$SRC" > "$W/b" 2>&1 || { echo "FAIL vec-guard: does not build"; grep -v warning "$W/b" | head -3; exit 1; }
vec=$(grep -n 'LOOP-VEC' "$SRC" | cut -d: -f1)
fake=$(grep -n 'LOOP-FAKE' "$SRC" | cut -d: -f1)
for d in cpu gpu; do
    XC_PAR=$d XC_PAR_REPORT=1 "$W/x" > "$W/r.$d" 2>&1
    got=$(grep -v '^par: ' "$W/r.$d")
    [ "$got" = "$want" ] || { echo "FAIL vec-guard: $d gives '$got', clang++'s '$want'"; fail=1; }
    [ $d = gpu ] && continue
    # gather runs twice: as a block for the apart call, serially for the
    # one-vector call. gatherFake never runs as a block.
    v=$(grep -c "vecguard.cpp:$vec: [0-9]* items on" "$W/r.$d")
    f=$(grep -c "vecguard.cpp:$fake: [0-9]* items on" "$W/r.$d")
    [ "$v" = 1 ] || { echo "FAIL vec-guard: the vector gather ran as a block $v times of its 2 calls (want 1: not the one-vector call)"; grep "vecguard.cpp:$vec" "$W/r.$d"; fail=1; }
    [ "$f" = 0 ] || { echo "FAIL vec-guard: the gather through a struct that is not a vector ran as a block"; fail=1; }
done
[ $fail = 0 ] && { echo "--- vec-guard: pass ---"; exit 0; }
echo "--- vec-guard: FAIL ---"
exit 1
