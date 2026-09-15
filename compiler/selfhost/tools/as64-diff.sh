#!/bin/bash
# as64-diff.sh — the ported arm64 assembler against XAArm64Assembler.
# =================================================================
#
# self-hosting M18. The oracle is `xcc-ln-arm64 --dump`, which prints everything
# the reference assembler produced — section bytes, symbol offsets, fixups — in
# a canonical order. Both sides run over the SAME `.s`, so any difference is in
# the encoding and nowhere else.
#
# The `.s` files come from compiling the corpus with `-S`; the runtime crt the
# driver normally prepends is not needed, because nothing here links.
#
#   bash selfhost/tools/as64-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/as64diff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtas64 (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtas64" selfhost/tools/xtas64.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtas64" ]; then
    grep -a error "$WORK/build.log" | head -5
    exit 1
fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)

pass=0; fail=0; oracle=0
declare -a FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc" -A arm64 -H . "${RUN_INCS[@]}" -S -o "$WORK/a.s" "$f" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-ln-arm64" --dump "$WORK/a.s" > "$WORK/a.txt" 2>/dev/null; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtas64" "$WORK/a.s" > "$WORK/b.txt" 2>"$WORK/b.err"; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if diff -q "$WORK/a.txt" "$WORK/b.txt" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(diff "$WORK/a.txt" "$WORK/b.txt" | grep -c '^[<>]') lines)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- as64-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
