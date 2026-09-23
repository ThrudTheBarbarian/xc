#!/bin/bash
# ldx86so-diff.sh — the ported ELF SHARED-OBJECT writer against XTElfWriter.
# =================================================================
# The twin of ldx86-diff, for `.so`s. Both linkers get the same `.s`, soname
# and interface blob, and their output files are compared byte for byte.
#
# Its own harness for the same reason lddylib-diff is: a shared object is not a
# variation on an executable. It has a .dynsym/.dynstr/.hash/.rela.dyn set no
# static image carries, a DT_SONAME, GLOB_DAT relocations for every import and
# a thunk per call — and nothing else in the tree emits any of that on x86-64.
#
#   bash selfhost/tools/ldx86so-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ldx86sodiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtx86so (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtx86so" selfhost/tools/xtx86so.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtx86so" ]; then
    grep -a error "$WORK/build.log" | head -5
    exit 1
fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)

pass=0; fail=0; oracle=0
declare -a FAILED

FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # --emit-lib: a library build is what this writer is for, and it is what
    # marks the public methods `.globl` — which is the export list.
    if ! "$BIN/xcc-fe" -A x86_64 -H . "${RUN_INCS[@]}" -q --emit-lib "$f" \
         -o "$WORK/a.ir" >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-x86_64" -O0 -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1 \
       || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    IFACE="$WORK/a.ir.iface"; [ -f "$IFACE" ] || IFACE=-
    if ! "$BIN/xcc-ln-x86_64" -shared -soname libX.so -iface "$IFACE" \
         "$WORK/a.s" -o "$WORK/a.so" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtx86so" -soname libX.so -iface "$IFACE" \
         "$WORK/a.s" -o "$WORK/b.so" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.so" "$WORK/b.so"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.so" "$WORK/b.so" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- ldx86so-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
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

