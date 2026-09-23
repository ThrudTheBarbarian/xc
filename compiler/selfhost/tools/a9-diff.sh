#!/bin/bash
# a9-diff.sh — the ported ARMv7-A back end against xcc-cg-arm9.
# =================================================================
#
# self-hosting M8. The front end is done and bootstraps; this is the BACK end,
# and the Zynq Cortex-A9 is the machine that has to host the compiler in the
# end — a code generator that only exists in Objective-C cannot go there.
#
# The oracle is `xcc-cg-arm9 -O0 --pic` over the same IR — --pic because that is
# what the driver actually passes for the Tier-2 loader-hosted .so: the assembly text must come
# out byte for byte the same. -O0 because the optimiser is its own port, and at
# -O0 the pipeline is a pass-through — so what is compared is the CODE
# GENERATOR alone.
#
#   bash selfhost/tools/a9-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
# LEVEL: the IR opt level BOTH sides are fed. It was hardcoded at 0 — the level
# nobody ships, since `make corpus` and the driver default are both -O3 — so the
# ported back end had only ever been compared on UNOPTIMISED IR (task #48).
#
# At a non-zero level the shapes differ, and the difference is load-bearing
# (bug 065, learned on arm64): the port runs no opt pipeline of its own, so it
# must be handed the REFERENCE's post-opt IR via --dump-opt-ir, while the
# reference side stays the DIRECT -O$LEVEL build. Feeding that optimised IR back
# in at -O0 is NOT a neutral back-end-only run: -O0 re-runs the
# static-init-guard pass over already-hoisted IR and destroys the hoist blocks,
# reporting a divergence neither back end has.
#
# -O0 deliberately keeps the legacy shape (pre-opt IR, -O0 oracle) so this
# change cannot move the existing baseline. Note that bug 065 found exactly that
# shape on arm64 was comparing the two back ends on DIFFERENT IR and agreeing by
# coincidence; whether the same is true here is a question for the -O3
# remediation pass, not something to silently alter while adding a harness.
LEVEL=${1:-0}
PATTERN=${2:-}
# The first argument is now the LEVEL, not the pattern. Someone who types the
# old `<harness>-diff.sh somefixture` would otherwise get `-Osomefixture` handed
# to the back end, which fails in a way that looks like a compiler bug. Refuse
# instead of guessing.
case "$LEVEL" in
    0|1|2|3) ;;
    *) echo "$(basename "$0"): first argument is the opt LEVEL (0-3), not a pattern." >&2
       echo "  did you mean: $(basename "$0") 0 '$LEVEL'" >&2
       exit 2 ;;
esac

WORK=${TMPDIR:-/tmp}/a9diff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtcg9 (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtcg9" selfhost/tools/xtcg9.xc \
    -I selfhost/ir -I selfhost/codegen 2>&1 | grep -E "^[^ ].*error" && exit 1

# arm9 resolves `#import <c>` against the device libc.so, so without the
# loader's build dir on the library path the ORACLE cannot compile most of the
# tree and the sweep silently shrinks to what needs no libc.
# Candidates, in order: an explicit XTC_ARM9_SYSROOT, the loader's build dir
# (either spelling, either tree layout), then the INSTALLED sysroot that
# `make install` vendors. A single hard-coded relative path is not where the
# loader builds, and nothing pointed at it, so `xcc-fe -m arm9`
# failed on every file that imports Stdio, and the harness scored 0 passes and
# 853 SKIPPED while reporting ok. A harness that compares nothing is not green;
# see the pass=0 check below.
. "$(dirname "$0")/arm9-sysroot.sh"
LIBARGS=()
if [ -n "$ARM9_SYSROOT" ]; then
    LIBARGS=(-L "$ARM9_SYSROOT")
    echo "arm9 sysroot: $ARM9_SYSROOT"
else
    echo "--- a9-diff: BROKEN (no arm9 sysroot with a libc.so found)"
    echo "    set XTC_ARM9_SYSROOT=<loader build dir>; without it the ORACLE"
    echo "    cannot compile anything that imports Stdio and NOTHING is compared."
    exit 1
fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/codegen)

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # ${LIBARGS[@]} unguarded is an "unbound variable" under `set -u` on bash 3.2
    # (macOS), which treats an EMPTY array as unset — so the whole stage aborted
    # in 4s with no summary whenever the sysroot was absent, as it is in any
    # checkout without XTC_ARM9_SYSROOT set.
    if ! "$BIN/xcc-fe" -m arm9 -H . "${RUN_INCS[@]}" ${LIBARGS[@]+"${LIBARGS[@]}"} "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-arm9" "-O$LEVEL" --pic -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    IN="$WORK/a.ir"
    if [ "$LEVEL" != 0 ]; then
        "$BIN/xcc-cg-arm9" "-O$LEVEL" --pic --dump-opt-ir -q "$WORK/a.ir" > "$WORK/opt.ir" 2>/dev/null \
            || { oracle=$((oracle+1)); continue; }
        IN="$WORK/opt.ir"
    fi
    "$WORK/xtcg9" "$IN" -o "$WORK/b.s" >/dev/null 2>&1
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
    echo "--- a9-diff: BROKEN (0 files compared; $oracle oracle failures)"
    exit 1
fi
echo "--- a9-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
# NOTHING COMPARED is not a pass. Every one of these harnesses counts an oracle
# failure — a file the REFERENCE could not build — and skips it, so a broken
# oracle turns the whole sweep into skips and the summary reads pass=0 fail=0.
# Only `fail` was ever checked, so that exited 0 and showed as a clean row in
# all-diff's table. It has now happened twice on ldx86-diff alone, the second
# time hiding 961 uncompared files. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi

