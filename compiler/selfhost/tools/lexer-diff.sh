#!/bin/bash
# lexer-diff.sh — the M4 differential test: the xtc lexer must agree with the
# Objective-C one, token for token, on every input we have.
#
#   selfhost/tools/lexer-diff.sh              # every fixture + every library
#   selfhost/tools/lexer-diff.sh a.xc b.xc    # just these files
#   VERBOSE=1 selfhost/tools/lexer-diff.sh    # show the first differing lines
#
# Both sides print one line per token — <line> <col> <type> <intValue> <text> —
# and the comparison is a byte diff. There is no "close enough": a lexer that
# disagrees anywhere disagrees, and the whole point of porting a module first is
# that its output is exactly comparable.
#
# The xtc side is built once, as a native arm64 binary, from selfhost/tools/
# xtlex.xc. The oracle is `xcc-fe --dump-tokens`, which lexes a RAW file — no
# preprocessing, no includes, no sema — so the comparison isolates the lexer.
set -u
cd "$(dirname "$0")/../.." || exit 1

XTC=bin/osx/xcc
FE=bin/osx/xcc-fe
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$XTC" ] || [ ! -x "$FE" ]; then
    echo "lexer-diff: build first (make)" >&2
    exit 1
fi

echo "building xtlex (xtc → native arm64)…"
if ! "$XTC" -H . -q -A arm64 -I selfhost/lexer selfhost/tools/xtlex.xc -o "$TMP/xtlex" 2>"$TMP/build.err"; then
    echo "lexer-diff: xtlex failed to build" >&2
    cat "$TMP/build.err" >&2
    exit 1
fi

if [ $# -gt 0 ]; then
    files=("$@")
else
    # Every fixture and every library source: between them they cover the
    # language, inline asm, and the awkward corners (apostrophes in asm
    # comments, `#` immediates, binary literals).
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find tests/fixtures support selfhost -name '*.xc' | sort \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i'
    )
fi

pass=0; fail=0; skip=0
failed_files=()
for f in "${files[@]}"; do
    [ -f "$f" ] || { skip=$((skip+1)); continue; }
    "$FE" --dump-tokens "$f" > "$TMP/oracle.txt" 2>"$TMP/oracle.err"
    if [ $? -ne 0 ]; then
        echo "SKIP  $f (oracle could not read it)"
        skip=$((skip+1))
        continue
    fi
    "$TMP/xtlex" "$f" > "$TMP/port.txt" 2>"$TMP/port.err"
    if [ $? -ne 0 ]; then
        echo "FAIL  $f (xtlex exited non-zero)"
        fail=$((fail+1)); failed_files+=("$f")
        continue
    fi
    if diff -q "$TMP/oracle.txt" "$TMP/port.txt" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed_files+=("$f")
        echo "FAIL  $f ($(diff "$TMP/oracle.txt" "$TMP/port.txt" | grep -c '^[<>]') differing lines)"
        if [ "${VERBOSE:-0}" = "1" ]; then
            diff "$TMP/oracle.txt" "$TMP/port.txt" | head -20 | sed 's/^/      /'
        fi
    fi
done

echo "--- lexer-diff: pass=$pass fail=$fail skip=$skip ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
[ "$fail" = 0 ]
