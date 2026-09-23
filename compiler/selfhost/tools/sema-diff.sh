#!/bin/bash
# sema-diff.sh — the M6 analyser differential test: the xtc semantic analyser
# must stamp the same things on the tree as the Objective-C one.
#
#   selfhost/tools/sema-diff.sh              # every fixture + every library source
#   selfhost/tools/sema-diff.sh a.xc b.xc    # just these files
#   VERBOSE=1 selfhost/tools/sema-diff.sh    # show the first differing lines
#
# Unlike its three predecessors this one is NOT expected to pass yet — the
# analyser is being ported a pass at a time, and the number below is the
# measurement that says how far it has got. A file passes only when EVERY
# annotation on every node agrees, so early on the count is the count of files
# whose analysis is trivial. That is the point: it can only go up.
#
# Both sides preprocess, lex and parse with their own front end (all three agree
# byte for byte — lexer-diff, pp-diff, ast-diff), then ANALYSE, then dump the
# annotated tree. What is compared is therefore only what sema decides.
#
# The analyser's configuration is pinned identically on both sides — see the
# --dump-sema comment in src/xcc-fe/main.m. Sema's output depends on it.
set -u
cd "$(dirname "$0")/../.." || exit 1

XTC=bin/osx/xcc
FE=bin/osx/xcc-fe
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Every platform's lib, not just arm64's: a fixture may import an Atari-only
# System.xc or a win64 interface, and an unresolved import is now a hard error
# on both sides rather than a quietly-empty tree.
INCS=(-I support/generic/lib -I support/arm64/lib -I support/xt6502/lib
      -I support/arm9/lib -I support/atarist/lib -I support/x86_64/lib
      -I support/win64/lib -I support/win64/selfhost-iface -I support/6502/lib
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt)
# selfhost/asm and selfhost/codegen are deliberately NOT here. Both define
# Arm64.xc, M68k.xc and X86_64.xc, so putting them on one search path makes
# `#import "Arm64.xc"` resolve to whichever directory comes first — the
# assembler where the back end was meant, or the reverse. That is not extra
# coverage, it is a WRONG comparison: tried it, and it manufactured three
# "divergences" that were purely the wrong file being imported.

if [ ! -x "$XTC" ] || [ ! -x "$FE" ]; then
    echo "sema-diff: build first (make)" >&2
    exit 1
fi

echo "building xtsema (xtc → native arm64)…"
if ! "$XTC" -H . -q -A arm64 -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema \
        selfhost/tools/xtsema.xc -o "$TMP/xtsema" 2>"$TMP/build.err"; then
    echo "sema-diff: xtsema failed to build" >&2
    cat "$TMP/build.err" >&2
    exit 1
fi

if [ $# -gt 0 ]; then
    files=("$@")
else
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find tests/fixtures support selfhost -name '*.xc' | sort \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i'
    )
fi

pass=0; fail=0; oracle_stopped=0
: > "$TMP/failures.txt"
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    "$FE" --dump-sema "$f" "${INCS[@]}" > "$TMP/oracle.txt" 2>"$TMP/oracle.err"
    orc=$?
    "$TMP/xtsema" "${INCS[@]}" "$f" > "$TMP/port.txt" 2>/dev/null
    if [ "$orc" != 0 ]; then
        # The oracle could not produce a tree at all — an unresolvable import,
        # usually. That is a HARNESS or COMPILER bug, not a parser difference,
        # and it used to be silent: the oracle printed an empty `Program`,
        # exited 0, and this script wrote it off as "stopped early" (#836).
        oracle_stopped=$((oracle_stopped+1))
        echo "  ORACLE FAILED  $f: $(head -1 "$TMP/oracle.err" | tr -d '\033')" >&2
    elif diff -q "$TMP/oracle.txt" "$TMP/port.txt" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        n=$(diff "$TMP/oracle.txt" "$TMP/port.txt" | grep -c '^[<>]')
        echo "$n $f" >> "$TMP/failures.txt"
        if [ "${VERBOSE:-0}" = "1" ]; then
            echo "FAIL  $f ($n differing lines)"
            diff "$TMP/oracle.txt" "$TMP/port.txt" | head -12 | sed 's/^/      /'
        fi
    fi
done

if [ -s "$TMP/failures.txt" ]; then
    echo "--- closest failures (differing lines, file):"
    sort -n "$TMP/failures.txt" | head -15
fi
echo "--- sema-diff: pass=$pass fail=$fail oracle-failed=$oracle_stopped ---"
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

[ "$fail" = 0 ]
