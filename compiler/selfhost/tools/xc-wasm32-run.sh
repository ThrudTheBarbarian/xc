#!/bin/bash
# xc-wasm32-run.sh — the SHIPPED compiler's wasm32 target, EXECUTED.
# ===================================================================
#
# Compiles fixtures with `xcc-xc -A wasm32` and RUNS each one under Node, then
# diffs against the fixture's expected output.
#
# This exists because of bug 083. A stored callback trapped at runtime on wasm32
# from the shipped compiler, and nothing saw it: `wasm-diff` compares the two
# BACK ENDS on the same IR and was green at 1360/0, while the fault was in the
# FRONT END — wasm32 missing from three per-platform lists, so it inherited the
# 6502's itable policy, ARCH_ macro and pointer width. A back-end differential
# cannot see a front-end difference, and no fixture in it stored a callback.
#
# So: build it the way a user does, run it, and compare what it printed.
#
#   bash selfhost/tools/xc-wasm32-run.sh [pattern]
set -u
cd "$(dirname "$0")/../.." || exit 1

BIN=bin/osx
[ -x "$BIN/xcc-xc" ] || BIN=bin/linux
PATTERN=${1:-}
FIX=tests/fixtures
# Build the compiler under test FIRST. `make` alone does not relink xcc-xc — it
# is its own target — so an edit to selfhost/ leaves a stale binary here that
# runs happily and produces yesterday's code. That is not hypothetical: a stale
# xcc-xc emitting the OLD 2-byte ARC sequence against a freshly widened 40-byte
# object header turned this sweep from 383/0 into 309/74, and every failure
# looked like a miscompile in the change under test.
make -s production >/dev/null 2>&1 || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! command -v node >/dev/null 2>&1; then
    echo "--- xc-wasm32-run: SKIPPED (no node) ---"
    exit 0
fi

pass=0; fail=0; buildfail=0; skipped=0; noexp=0; oracle=0
declare -a FAILED
for f in "$FIX"/*.xc; do
    b=$(basename "$f" .xc)
    [ -n "$PATTERN" ] && [[ "$b" != *"$PATTERN"* ]] && continue
    [ -f "$FIX/$b.expected.out" ] || { noexp=$((noexp+1)); continue; }
    hdr=$(head -30 "$f")
    printf '%s' "$hdr" | grep -q '^//xtc-.*skip'  && { skipped=$((skipped+1)); continue; }
    printf '%s' "$hdr" | grep -q '^//xtc-link:'   && { skipped=$((skipped+1)); continue; }
    na=$(printf '%s' "$hdr" | sed -n 's|^//xtc-na: *||p' | head -1)
    case ",$(printf '%s' "$na" | tr -d ' ')," in *,wasm32,*) skipped=$((skipped+1)); continue ;; esac
    tgt=$(printf '%s' "$hdr" | sed -n 's|.*target=\([A-Za-z0-9_]*\).*|\1|p' | head -1)
    if [ -n "$tgt" ] && [ "$tgt" != both ]; then skipped=$((skipped+1)); continue; fi

    # The REFERENCE is the oracle. A fixture the reference cannot build or run
    # on wasm32 is not applicable to this target — 6502 inline asm, a Gfx
    # library that has no wasm port, host imports Node does not supply — and
    # counting it against the SHIPPED compiler would report ~50 failures that
    # are nothing to do with it. Same rule the differentials use: what the
    # oracle could not produce was never compared, and is not a pass either.
    if ! "$BIN/xcc" -A wasm32 -H . -o "$WORK/r_$b.wasm" "$f" > "$WORK/r_$b.log" 2>&1 \
       || ! timeout 20 node "$WORK/r_$b.js" > "$WORK/r_$b.out" 2>&1 \
       || ! diff -q "$FIX/$b.expected.out" "$WORK/r_$b.out" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-xc" -A wasm32 -H . -o "$WORK/$b.wasm" "$f" > "$WORK/$b.log" 2>&1; then
        buildfail=$((buildfail+1))
        FAILED+=("$b — build: $(grep -m1 -o 'error:.*' "$WORK/$b.log" | cut -c1-70)")
        continue
    fi
    if ! timeout 20 node "$WORK/$b.js" > "$WORK/$b.out" 2>&1; then
        fail=$((fail+1))
        FAILED+=("$b — $(head -1 "$WORK/$b.out" | cut -c1-70)")
        continue
    fi
    if diff -q "$FIX/$b.expected.out" "$WORK/$b.out" >/dev/null 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$b — output differs ($(diff "$FIX/$b.expected.out" "$WORK/$b.out" | grep -c '^[<>]') lines)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- failures (first 20):"
    printf '  %s\n' "${FAILED[@]}" | head -20
fi
echo "--- xc-wasm32-run: pass=$pass fail=$fail build-failed=$buildfail not-applicable=$skipped oracle-failed=$oracle no-oracle=$noexp ---"
[ "$fail" = 0 ] && [ "$buildfail" = 0 ]
