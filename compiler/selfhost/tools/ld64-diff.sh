#!/bin/bash
# ld64-diff.sh — the ported Mach-O writer against XTMachOWriter.
# =================================================================
#
# self-hosting M19. Both linkers get the SAME `.s` and their OUTPUT FILES are
# compared byte for byte — a stronger oracle than any dump, because it covers
# the load commands, the link-edit tables and the ad-hoc code signature at once.
# The signature is a SHA-256 of the file's own pages, so a single byte out of
# place anywhere fails the comparison.
#
#   bash selfhost/tools/ld64-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ld64diff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtld64 (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtld64" selfhost/tools/xtld64.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtld64" ]; then
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
    if ! "$BIN/xcc-ln-arm64" "$WORK/a.s" "$WORK/a.bin" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtld64" "$WORK/a.s" "$WORK/b.bin" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.bin" "$WORK/b.bin"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.bin" "$WORK/b.bin" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- ld64-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
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

