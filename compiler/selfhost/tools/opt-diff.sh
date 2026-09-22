#!/bin/bash
# opt-diff.sh — the ported IR optimiser against the original's.
# =================================================================
#
# self-hosting M13. `xtcg-<arch> -O<n> --dump-opt-ir` prints the IR the
# original's opt pipeline produced; `xtopt` runs the PORTED pipeline over the
# same input. Identical means BYTE FOR BYTE, and every `.xc` in the tree is a
# case at whatever level is asked for.
#
#   bash selfhost/tools/opt-diff.sh [target] [level] [pattern]
#
# XTC_OPT_STOP_AFTER=<pass name> compares only the pipeline UP TO that pass, on
# both sides — which is what makes a single pass measurable before the twenty
# after it are ported.
#
# A file whose IR the port cannot read, or which needs a pass that is not
# ported, exits 3 and says which — it is counted `unsupported` and never as a
# pass. That list IS the work queue.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
TARGET=${1:-arm64}
LEVEL=${2:-1}
PATTERN=${3:-}
# The LEVEL is a bare number. Passing `-O3` makes `-O$LEVEL` into `-O-O3`, the
# oracle then produces nothing for every fixture, and the run reports
# `pass=0 fail=0 oracle-failed=959` — which reads like a result and is not one.
# Refuse it instead: a gate that cannot run must say so and stop, not return
# zeros that a caller may read as agreement.
case "$LEVEL" in
    0|1|2|3) ;;
    *) echo "opt-diff: LEVEL must be a bare 0-3, got '$LEVEL'" >&2
       echo "          usage: bash selfhost/tools/opt-diff.sh [target] [0-3] [pattern]" >&2
       exit 2 ;;
esac
WORK=${TMPDIR:-/tmp}/optdiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# The code generator that owns the pipeline for this target — the oracle is the
# pipeline, not the backend, but the pipeline is only reachable through it.
case "$TARGET" in
    arm64)   CG=$BIN/xcc-cg-arm64;  FEM=arm64 ;;
    arm9)    CG=$BIN/xcc-cg-arm9;   FEM=arm9 ;;
    atarist) CG=$BIN/xcc-cg-68k;    FEM=atarist ;;
    x86_64)  CG=$BIN/xcc-cg-x86_64; FEM=x86_64 ;;
    win64)   CG=$BIN/xcc-cg-win64;  FEM=win64 ;;
    xt|xt6502) CG=$BIN/xcc-cg-6502; FEM=xt ;;
    *) echo "opt-diff: unknown target '$TARGET'"; exit 1 ;;
esac

echo "building xtopt (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtopt" selfhost/tools/xtopt.xc \
    -I selfhost/ir -I selfhost/opt 2>&1 | grep -E "^[^ ].*error" && exit 1

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir)
# arm9 resolves `#import <c>` against the device libc.so; without it the ORACLE
# cannot compile most of the tree.
ARM9_SYSROOT=${XTC_ARM9_SYSROOT:-}
LIBARGS=()
[ "$TARGET" = arm9 ] && [ -d "$ARM9_SYSROOT" ] && LIBARGS=(-L "$ARM9_SYSROOT")

# Per-pass comparison: the oracle stops after the named pass, and so does the
# port. Same name on both sides — the pipeline's own pass names.
STOP=${XTC_OPT_STOP_AFTER:-}
STOPARGS=()
[ -n "$STOP" ] && STOPARGS=(--stop-after "$STOP")

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # Pre-opt IR: what both pipelines are given.
    if ! "$BIN/xcc-fe" -m "$FEM" -H . "${RUN_INCS[@]}" ${LIBARGS[@]+"${LIBARGS[@]}"} \
         "$f" -o "$WORK/pre.ir" >/dev/null 2>&1 || [ ! -s "$WORK/pre.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! XTIR_OPT_STOP_AFTER="$STOP" "$CG" "-O$LEVEL" --dump-opt-ir -q "$WORK/pre.ir" \
         -o "$WORK/oracle.ir" >/dev/null 2>&1 \
       || [ ! -s "$WORK/oracle.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    "$WORK/xtopt" "$WORK/pre.ir" -m "$TARGET" "-O$LEVEL" ${STOPARGS[@]+"${STOPARGS[@]}"} \
        -o "$WORK/port.ir" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 3 ]; then
        unsup=$((unsup+1))
        FAILED+=("$f — $("$WORK/xtopt" "$WORK/pre.ir" -m "$TARGET" "-O$LEVEL" \
                          ${STOPARGS[@]+"${STOPARGS[@]}"} 2>&1 \
                          | sed 's/.*unsupported: //' | head -1)")
        continue
    fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/oracle.ir" "$WORK/port.ir" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(diff "$WORK/oracle.ir" "$WORK/port.ir" | grep -c '^[<>]') lines)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing / unsupported (first 25):"
    printf '  %s\n' "${FAILED[@]}" | head -25
fi
if [ "$pass" -eq 0 ] && [ "$oracle" -gt 0 ]; then
    echo "!!! the oracle produced NOTHING for -m $TARGET — is that a target it knows?"
fi
echo "--- opt-diff[$TARGET -O$LEVEL${STOP:+ →$STOP}]: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
