#!/bin/bash
# installed-sweep.sh — does the INSTALLED compiler actually work?
# ================================================================
#
# `make corpus` and the differentials all run against the source tree. This runs
# against what a developer installs: /opt/xcc/<version>/bin/xcc, which is the
# XC compiler, resolving its support tree from its own location with no -H and
# no repo in sight.
#
# That is a different question from "does the build pass", and it is the one
# that matters to whoever installed it. It catches a whole class the in-tree
# gates cannot see: a support file that never got installed, a prune that
# removed something still needed, a binary that resolves its home differently
# once it is somewhere else.
#
#   bash selfhost/tools/installed-sweep.sh [prefix] [pattern]
#
# Default prefix is /opt/xcc/<VERSION>. Compiles each applicable fixture for the
# host, RUNS it, and diffs against the fixture's expected output — a fixture
# that builds but prints the wrong thing is a failure, not a pass.
set -u
cd "$(dirname "$0")/../.." || exit 1

VER=$(cat VERSION 2>/dev/null || echo 0.5)
PREFIX=${1:-/opt/xcc/$VER}
PATTERN=${2:-}
XCC="$PREFIX/bin/xcc"
FIX=tests/fixtures
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$XCC" ]; then
    echo "--- installed-sweep: SKIPPED (no compiler at $XCC — run 'make install') ---"
    exit 0
fi
echo "using $XCC — $("$XCC" -v 2>&1 | head -1)"

pass=0; fail=0; buildfail=0; skipped=0; noexp=0
declare -a FAILED
for f in "$FIX"/*.xc; do
    b=$(basename "$f" .xc)
    [ -n "$PATTERN" ] && [[ "$b" != *"$PATTERN"* ]] && continue
    # No expected output means there is nothing to check against — counted as
    # skipped rather than passed, because "it ran" is not a result.
    [ -f "$FIX/$b.expected.out" ] || { noexp=$((noexp+1)); continue; }
    hdr=$(head -30 "$f")
    printf '%s' "$hdr" | grep -q '^//xtc-.*skip'  && { skipped=$((skipped+1)); continue; }
    # //xtc-link: is two compilation units; the xc driver still refuses multiple
    # .xc inputs, so it is not something this can build.
    printf '%s' "$hdr" | grep -q '^//xtc-link:'   && { skipped=$((skipped+1)); continue; }
    na=$(printf '%s' "$hdr" | sed -n 's|^//xtc-na: *||p' | head -1)
    case ",$(printf '%s' "$na" | tr -d ' ')," in *,arm64,*) skipped=$((skipped+1)); continue ;; esac
    tgt=$(printf '%s' "$hdr" | sed -n 's|.*target=\([A-Za-z0-9_]*\).*|\1|p' | head -1)
    if [ -n "$tgt" ] && [ "$tgt" != both ] && [ "$tgt" != arm64 ]; then
        skipped=$((skipped+1)); continue
    fi

    if ! "$XCC" -o "$WORK/$b" "$f" > "$WORK/$b.log" 2>&1; then
        buildfail=$((buildfail+1))
        FAILED+=("$b — build: $(grep -m1 -o 'error:.*' "$WORK/$b.log" | cut -c1-70)")
        continue
    fi
    if ! timeout 10 "$WORK/$b" > "$WORK/$b.out" 2>&1; then
        fail=$((fail+1)); FAILED+=("$b — ran but exited non-zero"); continue
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
# no-expected is reported APART from not-applicable. They are both "not
# compared", but they mean different things: one is a fixture this target does
# not cover, the other is a fixture with no oracle at all — a gap in the
# fixtures rather than in the target.
echo "--- installed-sweep: pass=$pass fail=$fail build-failed=$buildfail not-applicable=$skipped no-oracle=$noexp ---"
[ "$fail" = 0 ] && [ "$buildfail" = 0 ]
