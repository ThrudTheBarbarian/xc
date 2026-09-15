#!/bin/bash
# ast-diff.sh — the M5 parser differential test: the xtc parser must build the
# same tree as the Objective-C one.
#
#   selfhost/tools/ast-diff.sh              # every fixture + every library source
#   selfhost/tools/ast-diff.sh a.xc b.xc    # just these files
#   VERBOSE=1 selfhost/tools/ast-diff.sh    # show the first differing lines
#
# Both sides preprocess with their OWN preprocessor first (the two agree byte
# for byte — pp-diff.sh), then lex and parse, then dump the tree as
# S-expressions in XTASTDumper's format. Sema does not run on either side: what
# is compared is what the parser decides.
#
# Unlike the lexer and preprocessor, this one is NOT expected to be at 100% yet.
# The pass count is the measurement — it is what tells us how much of the
# language the ported parser covers, and each failure names a construct.
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
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser
      -I selfhost/sema -I selfhost/ir)

if [ ! -x "$XTC" ] || [ ! -x "$FE" ]; then
    echo "ast-diff: build first (make)" >&2
    exit 1
fi

echo "building xtast (xtc → native arm64)…"
if ! "$XTC" -H . -q -A arm64 -I selfhost/lexer -I selfhost/preproc -I selfhost/parser \
        selfhost/tools/xtast.xc -o "$TMP/xtast" 2>"$TMP/build.err"; then
    echo "ast-diff: xtast failed to build" >&2
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
    "$FE" --dump-ast "$f" "${INCS[@]}" > "$TMP/oracle.txt" 2>"$TMP/oracle.err"
    orc=$?
    "$TMP/xtast" "${INCS[@]}" "$f" > "$TMP/port.txt" 2>/dev/null
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
echo "--- ast-diff: pass=$pass fail=$fail oracle-stopped=$oracle_stopped ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
[ "$fail" = 0 ]
