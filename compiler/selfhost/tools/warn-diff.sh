#!/bin/bash
# warn-diff.sh — the analyser's fixtures: what MUST warn, and what must not.
# =================================================================
# Every other harness compares two compilers on artefacts — tokens, AST, IR,
# assembly. A diagnostic is in none of them, so an analyser could rot in
# exactly the way ten sema rules did: present in one compiler, absent in the
# other, every differential green (private:docs/bugs/078).
#
# Subjects are tests/warn/*.xc. A leading `//xtc-warn: <text>` line names a
# substring that must appear in the compiler's output; a fixture with none must
# produce NO warning at all, which is what catches a false positive.
#
# stderr ONLY. That is where a diagnostic belongs and where the analyser now
# writes: `xcc-fe --dump-*` puts its artefact on stdout, and the differentials
# compare that artefact byte for byte. Checking stderr alone means this harness
# also proves the separation, not just the text.
#
# The analyser is the SHIPPED compiler's alone (private:docs/Design/static-analysis.md
# §1), so there is no oracle to compare against — the fixtures ARE the oracle.
#
#   bash selfhost/tools/warn-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/warndiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

XCC="$BIN/xcc-xc"
if [ ! -x "$XCC" ]; then
    echo "--- warn-diff: BROKEN (bin/xcc-xc is missing — run 'make production')"
    exit 1
fi

pass=0; fail=0
declare -a FAILED

shopt -s nullglob
for f in tests/warn/*.xc; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # A fixture's own flags ride on the same `//xtc-flags:` line the corpus uses.
    FLAGS=$(sed -n 's|^//xtc-flags: *||p' "$f" | head -1)
    "$XCC" -A arm64 -H . -Wanalyze $FLAGS -o "$WORK/out" "$f" > "$WORK/o.txt" 2> "$WORK/e.txt"
    rc=$?
    # A warning must NEVER change the exit status, and must never suppress the
    # output — both are hard rules from the design, and both are the kind of
    # thing that only shows up when something downstream breaks.
    if [ $rc -ne 0 ]; then
        fail=$((fail+1)); FAILED+=("$(basename "$f"): exit $rc — a warning must not fail the build")
        continue
    fi
    # …and it must not have gone to STDOUT, which is where a dump goes.
    if grep -q 'warning:' "$WORK/o.txt"; then
        fail=$((fail+1))
        FAILED+=("$(basename "$f"): a warning reached STDOUT, where dumps are written")
        continue
    fi
    want=$(sed -n 's|^//xtc-warn: *||p' "$f")
    miss=""
    if [ -n "$want" ]; then
        while IFS= read -r w; do
            [ -z "$w" ] && continue
            grep -qF -- "$w" "$WORK/e.txt" || miss="$miss
    missing: $w"
        done <<< "$want"
    else
        if grep -q 'warning:' "$WORK/e.txt"; then
            miss="
    expected SILENCE, got: $(grep -m1 'warning:' "$WORK/e.txt")"
        fi
    fi
    if [ -z "$miss" ]; then pass=$((pass+1))
    else fail=$((fail+1)); FAILED+=("$(basename "$f"):$miss"); fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- failures:"
    printf '  %s\n' "${FAILED[@]}" | head -30
fi
echo "--- warn-diff: pass=$pass fail=$fail ---"
[ "$fail" -eq 0 ] || exit 1
