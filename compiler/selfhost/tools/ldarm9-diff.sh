#!/bin/bash
# ldarm9-diff.sh — the ported ARM32 SHARED-OBJECT writer against XTElf32Writer.
# =================================================================
# Both linkers get the same `.s`, soname and interface blob, and their output
# files are compared byte for byte.
#
# This is the harness that took the arm9 link in-house. `-A arm9` was the one
# live target the shipped compiler REFUSED, because nothing in the port could
# turn assembled ARM32 into the ET_DYN image the XTOS loader takes: veneers, a
# .hash/.dynsym/.dynstr/.rel.dyn set, DT_SONAME/DT_NEEDED and a GLOB_DAT per
# import. Elf32.xc wrote objects only — "the linker is the next piece".
#
#   bash selfhost/tools/ldarm9-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ldarm9diff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xta9so + xtcg9 (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xta9so" selfhost/tools/xta9so.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xta9so" ]; then
    grep -a error "$WORK/build.log" | head -5
    exit 1
fi
# a9-diff sweeps the tree in PROGRAM mode, where every internal symbol is
# `.hidden`. A library is the opposite — hiding them exports nothing and the
# app that links the .so dies at load naming a method the file plainly
# contains — and nothing was comparing that shape. Both code generators are
# already being run here, so comparing their `--emit-lib` output costs one
# `cmp` and closes it.
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtcg9" selfhost/tools/xtcg9.xc \
    -I selfhost/ir -I selfhost/codegen -I selfhost/opt > "$WORK/cgbuild.log" 2>&1
if [ ! -x "$WORK/xtcg9" ]; then
    grep -a error "$WORK/cgbuild.log" | head -5
    exit 1
fi

# Without a libc.so the ORACLE cannot compile anything that imports Stdio, and
# the sweep silently shrinks to what needs no libc. A harness that compares
# nothing is not green.
. "$(dirname "$0")/arm9-sysroot.sh"
LIBARGS=()
if [ -n "$ARM9_SYSROOT" ]; then
    LIBARGS=(-L "$ARM9_SYSROOT")
    echo "arm9 sysroot: $ARM9_SYSROOT"
else
    echo "--- ldarm9-diff: BROKEN (no arm9 sysroot with a libc.so found)"
    echo "    set XTC_ARM9_SYSROOT=<loader build dir>; without it NOTHING is compared."
    exit 1
fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)

pass=0; fail=0; oracle=0
declare -a FAILED

# The hand-written runtime FIRST, on its own and as a group. It is the only
# ARM32 assembly in the tree a compiler did not write, so it is the only place
# forms like a register-specified shift (`orr r1, r1, r0, lsr r3`) appear — and
# reading one of those as an immediate assembles, links, runs and is wrong
# (private:docs/bugs/103). Nothing assembled these files until the arm9 link came
# in-house, so nothing compared them.
RT=support/arm9/runtime
RT_FILES=("$RT/rtgen-arm9.s" "$RT/libxtgen-arm9.s" "$RT/aeabi64.s")
for one in "${RT_FILES[@]}" "ALL"; do
    if [ "$one" = ALL ]; then set -- "${RT_FILES[@]}"; label="the runtime, linked as one unit"
    else set -- "$one"; label=$one; fi
    if ! "$BIN/xcc-ln-arm9" --shared -o "$WORK/rt-a.so" "$@" >/dev/null 2>&1; then
        echo "!!! the ORACLE cannot link $label — nothing was compared"
        exit 1
    fi
    if ! "$WORK/xta9so" "$@" -o "$WORK/rt-b.so" >"$WORK/rt.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$label ($(head -1 "$WORK/rt.err"))"); continue
    fi
    if cmp -s "$WORK/rt-a.so" "$WORK/rt-b.so"; then pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$label ($(cmp -l "$WORK/rt-a.so" "$WORK/rt-b.so" | wc -l | tr -d ' ') bytes)")
    fi
done

FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # --emit-lib: a library build is what this writer is for, and it is what
    # marks the public methods `.globl` — which is the export list.
    if ! "$BIN/xcc-fe" -A arm9 -H . "${RUN_INCS[@]}" ${LIBARGS[@]+"${LIBARGS[@]}"} -q --emit-lib "$f" \
         -o "$WORK/a.ir" >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    # --pic --emit-lib: exactly what the driver's arm9 library path runs, so the
    # assembly under test is the assembly production produces.
    if ! "$BIN/xcc-cg-arm9" -O0 --pic --emit-lib -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1 \
       || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtcg9" --emit-lib "$WORK/a.ir" -o "$WORK/p.s" >/dev/null 2>&1 \
       || ! cmp -s "$WORK/a.s" "$WORK/p.s"; then
        fail=$((fail+1)); FAILED+=("$f (codegen --emit-lib differs)"); continue
    fi
    IFACE="$WORK/a.ir.iface"; [ -f "$IFACE" ] || IFACE=-
    if ! "$BIN/xcc-ln-arm9" --shared -soname libX.so -iface "$IFACE" \
         "$WORK/a.s" -o "$WORK/a.so" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xta9so" -soname libX.so -iface "$IFACE" \
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
echo "--- ldarm9-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
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

