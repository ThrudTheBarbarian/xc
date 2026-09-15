#!/bin/bash
# wrap65-diff.sh — the xt6502 RUNTIME WRAP, ported, against xcc-cg-6502.
# =====================================================================
#
# x65-diff compares the back ends and calls `strip_harness` on the oracle to do
# it: everything the runtime wrap adds — the harness, the per-`new` allocator
# stubs, the heap config, the lazy-linked heap/ARC/bank/float/i64 templates —
# was cut out of the comparison because the port had no equivalent. That is
# roughly two thirds of the emitted text, and it is the part that decides
# whether a program can allocate at all.
#
# This compares the WHOLE output: `xcc-cg-6502 -m xt -O0` against the ported
# back end plus Runtime6502's wrap. The lazy-link gate is driven by scanning the
# generated assembly, so a fixture that allocates, retains, uses a weak ref, a
# float or an i64 pulls in different templates — which is exactly the behaviour
# that needs comparing, and exactly what one hand-picked file cannot cover.
#
#   bash selfhost/tools/wrap65-diff.sh [pattern]
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
LAYOUT=support/xt6502/layouts/xt.lnk
WORK=${TMPDIR:-/tmp}/wrap65.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtcg65 (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtcg65" selfhost/tools/xtcg65.xc \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/driver \
    2>&1 | grep -E "^[^ ].*error" && exit 1
[ -x "$WORK/xtcg65" ] || { echo "--- wrap65-diff: BROKEN (xtcg65 did not build)"; exit 1; }

RUN_INCS=(-I support/xt6502/lib -I support/generic/lib)

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED

FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc-fe" -m xt -H . "${RUN_INCS[@]}" "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    # The oracle is the FULL text xcc-cg-6502 writes — harness, stubs, lazy
    # links and all. Nothing is stripped: that is the point.
    if ! "$BIN/xcc-cg-6502" -m xt -H . -O0 -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    "$WORK/xtcg65" "$WORK/a.ir" -L "$LAYOUT" --wrap support -o "$WORK/b.s" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 3 ]; then unsup=$((unsup+1)); continue; fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/a.s" "$WORK/b.s" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(diff "$WORK/a.s" "$WORK/b.s" | grep -c '^[<>]') lines)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
    echo "--- wrap65-diff: BROKEN (0 files compared; $oracle oracle failures)"
    exit 1
fi
echo "--- wrap65-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
