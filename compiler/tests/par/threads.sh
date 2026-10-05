#!/bin/bash
# threads.sh — every `par` fixture that runs gives the same answer on any
# number of threads (par-blocks.md §9).
#
# A block's chunks are folded in chunk order, so an integer result must not
# depend on how many threads the range was split across. Each fixture with an
# .expected.out is built once and run with XC_PAR_THREADS = 1 (no threads at
# all), 2, 3 (a split that does not divide the range) and 16 (more threads than
# most chunks), and every run must print the expected output. The compile
# itself must print nothing.
#
#   bash tests/par/threads.sh                 # this machine, with bin/<plat>/xcc-xc
#   XCC=path/to/xcc ARCH=x86_64 bash tests/par/threads.sh
#
# Run from compiler/. Exits non-zero when any run differs.
set -u
cd "$(dirname "$0")/../.." || exit 2
case "$(uname -s)" in Darwin) PLAT=osx ;; *) PLAT=linux ;; esac
XCC=${XCC:-bin/$PLAT/xcc-xc}
ARCH=${ARCH:-}
[ -x "$XCC" ] || { echo "threads: no compiler at $XCC"; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/par-threads.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT

pass=0; fail=0
for src in tests/fixtures/par_*.xc; do
    name=$(basename "$src" .xc)
    exp="tests/fixtures/$name.expected.out"
    [ -f "$exp" ] || continue
    if ! "$XCC" -q -H . ${ARCH:+-A "$ARCH"} -o "$WORK/$name" "$src" > "$WORK/$name.err" 2>&1; then
        echo "FAIL $name: does not build"; sed 's/^/    /' "$WORK/$name.err" | head -5
        fail=$((fail + 1)); continue
    fi
    # A clean fixture compiles in silence: anything printed is a warning it
    # should not have, or a stray print left in the compiler.
    if [ -s "$WORK/$name.err" ]; then
        echo "FAIL $name: the compiler printed:"; sed 's/^/    /' "$WORK/$name.err" | head -5
        fail=$((fail + 1)); continue
    fi
    ok=1
    for t in 1 2 3 16; do
        if ! XC_PAR_THREADS=$t timeout 60 "$WORK/$name" > "$WORK/$name.out" 2>&1 ||
           ! cmp -s "$WORK/$name.out" "$exp"; then
            echo "FAIL $name with XC_PAR_THREADS=$t:"; sed 's/^/    /' "$WORK/$name.out" | head -5
            ok=0
        fi
    done
    if [ $ok = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
echo "--- par threads${ARCH:+ ($ARCH)}: pass=$pass fail=$fail ---"
[ $fail = 0 ]
