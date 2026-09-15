#!/bin/bash
# ldandroid-diff.sh — the ported aarch64 ELF writer against XTElfArm64Writer.
# =================================================================
#
# Both linkers get the SAME `.s` and their OUTPUT FILES are compared byte for
# byte — a stronger oracle than any dump, because one comparison covers the
# program headers, the dynamic array, the hash table, the relocations, the GOT
# thunks and the section table at once.
#
# Linked as a `.so`: it needs no entry symbol, so every file in the corpus is a
# candidate, and an undefined symbol becomes an IMPORT rather than an error —
# which exercises more of the thunk/GLOB_DAT path than an executable would.
#
#   bash selfhost/tools/ldandroid-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ldandroiddiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtlnandroid (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtlnandroid" selfhost/tools/xtlnandroid.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtlnandroid" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)
NEEDED=libc.so,libm.so,libdl.so

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
    if ! "$BIN/xcc-ln-arm64" --android so libdiff.so - "$NEEDED" \
         "$WORK/a.s" "$WORK/a.so" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtlnandroid" so libdiff.so - "$NEEDED" \
         "$WORK/a.s" "$WORK/b.so" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.so" "$WORK/b.so"; then pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.so" "$WORK/b.so" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- ldandroid-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
