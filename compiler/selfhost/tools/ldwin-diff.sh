#!/bin/bash
# ldwin-diff.sh — the ported PE writer against XTPEWriter.
# =================================================================
#
# self-hosting M22. Both linkers get the same `.s` files and the same import
# map, and their .exe files are compared byte for byte.
#
#   bash selfhost/tools/ldwin-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ldwin.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtldwin (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtldwin" selfhost/tools/xtldwin.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtldwin" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

RT=(support/win64/runtime/crt-win64.s support/win64/runtime/rtgen-win64.s support/win64/runtime/rtfiles-win64.s
    support/win64/runtime/libmgen-win64.s)
MAP=support/win64/win32-imports.map
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
    if ! "$BIN/xcc" -A win64 -H . "${RUN_INCS[@]}" -S -o "$WORK/a.s" "$f" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-ln-win64" "$WORK/a.s" "${RT[@]}" -importmap "$MAP" -o "$WORK/a.exe" \
         >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtldwin" "$WORK/a.s" "${RT[@]}" -importmap "$MAP" -o "$WORK/b.exe" \
         >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.exe" "$WORK/b.exe"; then pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.exe" "$WORK/b.exe" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- ldwin-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
