#!/bin/bash
# cppcorpus.sh — the C++ path's corpus: programs in tests/par/cpp/ that use
# the language broadly (templates, multiple and virtual inheritance, lambdas,
# the containers, RAII and moves, operator overloading, exceptions, numeric
# kernels, struct layout, iterators, globals, strings, the parallel
# algorithms), each with loops for xcc to take. Each is built by clang++ -O2
# alone and by xcc, plain and with --par-style=auto (run on the CPU and the
# GPU); every xcc build must give clang++'s output. macOS (libc++) and Linux
# (libstdc++). Skipped where there is no clang++. Self-hosted compiler only.
#
#   bash tests/par/cppcorpus.sh [pattern]
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
# libc++'s parallel algorithms are its experimental library on macOS;
# libstdc++ (Linux) has them in the standard one.
EXP=$( [ "$(uname -s)" = Darwin ] && echo -fexperimental-library || echo )
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- cppcorpus: skipped (no clang++) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0; n=0; taken=0
for f in tests/par/cpp/${1:-}*.cpp; do
    b=$(basename "$f" .cpp)
    n=$((n + 1))
    clang++ -std=c++20 $EXP -O2 -w -o "$W/$b.ref" "$f" || { echo "FAIL cppcorpus: $b: clang++ does not build it"; fail=1; continue; }
    ref=$("$W/$b.ref")
    XC_C_TRACE=1 "$XC" -q -O3 -std=c++20 -H . -o "$W/$b" "$f" > "$W/$b.log" 2>&1 \
        || { echo "FAIL cppcorpus: $b does not build"; grep -v 'warning' "$W/$b.log" | sed -n 1,5p; fail=1; continue; }
    got=$("$W/$b" 2>&1)
    [ "$got" = "$ref" ] || { echo "FAIL cppcorpus: $b gives '$got', clang++'s '$ref'"; fail=1; }
    XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=auto -std=c++20 -H . -o "$W/$b.par" "$f" > "$W/$b.plog" 2>&1 \
        || { echo "FAIL cppcorpus: $b does not build with --par-style=auto"; grep -v 'warning' "$W/$b.plog" | sed -n 1,5p; fail=1; continue; }
    for d in cpu gpu; do
        got=$(XC_PAR=$d "$W/$b.par" 2>&1)
        [ "$got" = "$ref" ] || { echo "FAIL cppcorpus: $b ($d) gives '$got', clang++'s '$ref'"; fail=1; }
    done
    taken=$((taken + $(grep -c 'outlined, a block' "$W/$b.plog")))
done
echo "cppcorpus: $n programs, $taken blocks"
[ $fail = 0 ] && echo "--- cppcorpus: pass ---" || echo "--- cppcorpus: FAIL ---"
exit $fail
