#!/bin/bash
# obj64-diff.sh — the ported MACH-O OBJECT writer against XTMachOWriter.
# =================================================================
#
# `-c` writes an object. The port had no ELF64 object writer at all, so the
# shipped compiler rejected `-c` outright and a developer using the compiler
# that ships could not compile a module at a time (task #63).
#
# The twin of ld64-diff, for MH_OBJECT: both writers get the same assembly and
# their output files are compared byte for byte. Its own harness because an
# object is not a small executable — it has one UNNAMED segment holding both
# sections, an LC_DYSYMTAB saying where the undefined run starts, and
# ARM64_RELOC_ADDEND entries that must PRECEDE the pair they apply to, none of
# which any linked image carries.
#
#   bash selfhost/tools/obj64-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/obj64diff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtobj64 (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtobj64" selfhost/tools/xtobj64.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtobj64" ]; then
    grep -a error "$WORK/build.log" | head -5
    exit 1
fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)

pass=0; fail=0; oracle=0
declare -a FAILED
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # --object keeps every function the module defines: something in ANOTHER
    # object may call it, so cross-function DCE must not run. That is also what
    # makes this a wider test of the back end than a program build.
    if ! "$BIN/xcc-fe" -A arm64 -H . "${RUN_INCS[@]}" -q -c "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-arm64" -O0 -q --object -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1 \
       || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-ln-arm64" --object "$WORK/a.s" "$WORK/a.o" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtobj64" --object "$WORK/a.s" "$WORK/b.o" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.o" "$WORK/b.o"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.o" "$WORK/b.o" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- obj64-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
[ "$pass" -gt 0 ] || { echo "!!! nothing was compared"; exit 1; }
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

