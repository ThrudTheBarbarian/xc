#!/bin/bash
# as68-diff.sh — the ported 68k assembler against XAM68kAssembler.
# =================================================================
#
# self-hosting M23. The reference assembles in-process inside xcc-cg-68k, so the
# oracle is the whole GEMDOS $601A image: build the .prg one way, assemble the
# same `.s` the other, compare byte for byte. That covers the encoding, the
# two-pass label sizing, the segment split and the DRI relocation stream.
#
#   bash selfhost/tools/as68-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/as68.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtas68 (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtas68" selfhost/tools/xtas68.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtas68" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)

pass=0; fail=0; oracle=0
declare -a FAILED
declare -a ORACLE_FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # SAY WHICH. An oracle failure here is a whole m68k build refused, and
    # since bug 126 that includes "undefined symbol" — a program that used to
    # assemble a `jsr 0` and be compared as a PASS. Counting those silently
    # would turn 52 hollow passes into 52 invisible skips; naming them keeps
    # the coverage loss (bug 127) on the table until it is won back.
    if ! "$BIN/xcc" -A m68k -H . "${RUN_INCS[@]}" -o "$WORK/a.prg" "$f" >/dev/null 2>"$WORK/a.err" \
       || [ ! -s "$WORK/a.prg" ]; then
        oracle=$((oracle+1))
        ORACLE_FAILED+=("$f: $(sed 's/\x1b\[[0-9;]*m//g' "$WORK/a.err" \
                              | grep -m1 -E 'error' | cut -c1-100)")
        continue
    fi
    if ! "$BIN/xcc" -A m68k -H . "${RUN_INCS[@]}" -S -o "$WORK/a.s" "$f" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtas68" "$WORK/a.s" "$WORK/b.prg" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.prg" "$WORK/b.prg"; then pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.prg" "$WORK/b.prg" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "${#ORACLE_FAILED[@]}" -gt 0 ]; then
    echo "--- oracle could not build these (NOT compared, not passes):"
    printf '  %s\n' "${ORACLE_FAILED[@]}"
fi
echo "--- as68-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
