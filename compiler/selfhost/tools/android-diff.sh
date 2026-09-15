#!/bin/bash
# android-diff.sh — the ported arm64 back end under the ANDROID options.
# =================================================================
#
# arm64-diff already compares the two back ends, but only in their DEFAULT
# configuration — Darwin's argument ABI and LSE atomics. `-A android` flips
# both, and nothing else in the matrix exercises the flipped path: without this
# harness the ported options would sit there reporting byte-identical while
# never being executed, which is the shape a green matrix hides best.
#
#   bash selfhost/tools/android-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/androiddiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtcga64 (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtcga64" selfhost/tools/xtcga64.xc \
    -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm \
    > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtcga64" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/codegen)
OPTS=(--aapcs64-abi --no-lse-atomics)

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc-fe" -m arm64 -H . "${RUN_INCS[@]}" "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-arm64" "${OPTS[@]}" -O0 -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    # The port is fed the SAME pre-opt IR the oracle is, and runs its own
    # optimiser over it — so this compares the whole ported pipeline, not just
    # the back end, which is the stronger property and the reason to keep it.
    #
    # It went 0/719 when bug 065 changed how the ORIGINAL numbers frame slots
    # and the port kept the old numbering (065 landed in the reference only).
    # Feeding the port the reference's post-opt IR would have hidden that — the
    # printer renumbers densely, so both sides would agree by construction while
    # the actual disagreement survived. The port was mirrored instead; if this
    # harness ever needs post-opt IR to pass, that is the bug reappearing.
    "$WORK/xtcga64" "${OPTS[@]}" "$WORK/a.ir" -o "$WORK/b.s" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 3 ]; then unsup=$((unsup+1)); continue; fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/a.s" "$WORK/b.s" >/dev/null; then pass=$((pass+1))
    else fail=$((fail+1)); FAILED+=("$f ($(diff "$WORK/a.s" "$WORK/b.s" | grep -c '^[<>]') lines)"); fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- android-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
