#!/bin/bash
# wasm-diff.sh — the ported wasm32 back end against xcc-cg-wasm32.
# ================================================================
#
# self-hosting, wasm stage A. Every file is compared TWICE:
#
#   -O0  oracle `xcc-cg-wasm32 -O0` — the pipeline is a pass-through, so
#        this compares the CODE GENERATORS alone (the dispatch-loop form),
#        exactly as arm64-diff does for the host back end.
#   -O2  oracle `xcc-cg-wasm32 -O2` — both sides run their full opt
#        pipeline (byte-identical IR in), so what this compares is the two
#        STRUCTURIZERS: the -O1+ block/loop/if emission must agree byte for
#        byte, dense local numbering included.
#
# The summary keeps the `pass=N fail=N` shape all-diff.sh parses; the counts
# are totals ACROSS BOTH levels (so full green is 2× the file count).
#
#   bash selfhost/tools/wasm-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
# LEVELS: which opt levels to compare, space-separated. The default pair is the
# historical one; `wasmo3-diff.sh` passes O3, the level everything actually
# ships at and the one this had never been run at (task #48). Unlike the other
# back ends, xtcgwasm runs its OWN opt pipeline, so both sides optimise the same
# IR and there is no post-opt hand-off to arrange.
LEVELS=${1:-"O0 O2"}
PATTERN=${2:-}

# The first argument is now the LEVEL LIST, not the pattern — same trap as the
# other harnesses, so the same refusal.
for _l in $LEVELS; do
    case "$_l" in
        O0|O1|O2|O3) ;;
        *) echo "$(basename "$0"): first argument is a list of opt levels (e.g. \"O0 O2\"), not a pattern." >&2
           echo "  did you mean: $(basename "$0") \"O0 O2\" '$_l'" >&2
           exit 2 ;;
    esac
done

WORK=${TMPDIR:-/tmp}/wasmdiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtcgwasm (xtc → native arm64)…"
# -O1: at -O2 the arm64 call-body unroller currently tips Wasm32$placeData
# over the 16 KB frame budget; the tool's own opt level changes nothing
# about what it EMITS.
"$BIN/xcc" -O1 -A arm64 -H . -o "$WORK/xtcgwasm" selfhost/tools/xtcgwasm.xc \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen 2>&1 | grep -E "^[^ ].*error" && exit 1

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
    if ! "$BIN/xcc-fe" -A wasm32 -H . "${RUN_INCS[@]}" "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    for lvl in $LEVELS; do
        if ! "$BIN/xcc-cg-wasm32" "-$lvl" -q -o "$WORK/a.wat" "$WORK/a.ir" >/dev/null 2>&1; then
            oracle=$((oracle+1)); continue
        fi
        "$WORK/xtcgwasm" "-$lvl" "$WORK/a.ir" -o "$WORK/b.wat" >/dev/null 2>&1
        rc=$?
        if [ $rc -eq 3 ]; then unsup=$((unsup+1)); continue; fi
        if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f [$lvl] (exit $rc)"); continue; fi
        if diff -q "$WORK/a.wat" "$WORK/b.wat" >/dev/null; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
            FAILED+=("$f [$lvl] ($(diff "$WORK/a.wat" "$WORK/b.wat" | grep -c '^[<>]') lines)")
        fi
    done
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- wasm-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
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

