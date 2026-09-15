#!/bin/bash
# bootstrap.sh — the staged build. Does the self-hosted front end reproduce
# itself?
# =================================================================
#
# self-hosting M7. `fe-diff.sh` compares the two front ends' OUTPUT file by
# file; this asks the question that output comparison is a proxy for: can the
# compiler build itself, and does the result stop changing?
#
#   stage1 — xtfe built by the Objective-C toolchain
#   stage2 — xtfe built by a toolchain whose front end IS stage1
#   stage3 — xtfe built by a toolchain whose front end IS stage2
#
# The gate is **stage2 == stage3, byte for byte**. That is the fixed point: a
# compiler built by itself produces itself. stage1 == stage2 is the stronger
# claim and it is checked too — it follows from IR parity, and if it fails
# while stage2 == stage3 holds, the self-hosted front end is self-consistent
# but differs from the original somewhere.
#
# The comparison is on the ASSEMBLY each stage emits, not on the linked
# executable: ld64 stamps an LC_UUID that varies between two links of
# identical input, so two Mach-O files differ in 49 bytes no matter what
# compiled them. The `.s` is the whole compiler's output — front end and back
# end — and it IS reproducible, so it is the honest artefact to compare. Each
# stage therefore builds twice: an executable, to run the next stage with, and
# the assembly, to compare.
#
# The BACK end is the Objective-C `xcc-cg-arm64` throughout: M7 is the front
# end's bootstrap, and the back end has not been ported. Each stage is a real
# toolchain directory — `xtc` resolves `xcc-fe` as a sibling of argv[0], so
# dropping the self-hosted front end in beside it is all the substitution
# takes.
#
#   bash selfhost/tools/bootstrap.sh

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/bootstrap.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

INCS=(-I support/generic/lib -I support/arm64/lib -I support/xt6502/lib
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser
      -I selfhost/sema -I selfhost/ir)
SRC=selfhost/tools/xtfe.xc -I selfhost/driver

# Build the front end with the toolchain in $1: the executable as $2 and the
# assembly it came from as $2.s.
build_with() {
    local tools=$1 out=$2
    "$tools/xtc" -O2 -A arm64 -H . -o "$out" "$SRC" "${INCS[@]}" 2>&1 \
        | grep -E "error" && return 1
    "$tools/xtc" -O2 -A arm64 -H . -o "$out.s" "$SRC" "${INCS[@]}" 2>&1 \
        | grep -E "error" && return 1
    [ -x "$out" ] && [ -s "$out.s" ]
}

# A toolchain directory: the dispatcher, the back end, and a front end.
stage_dir() {
    local dir=$1 fe=$2
    mkdir -p "$dir"
    cp "$BIN/xcc" "$BIN/xcc-cg-arm64" "$dir/"
    cp "$fe" "$dir/xcc-fe"
}

echo "stage1: building xtfe with the Objective-C front end…"
build_with "$BIN" "$WORK/xtfe1" || { echo "stage1 FAILED"; exit 1; }

echo "stage2: building xtfe with stage1 as the front end…"
stage_dir "$WORK/t1" "$WORK/xtfe1"
build_with "$WORK/t1" "$WORK/xtfe2" || { echo "stage2 FAILED"; exit 1; }

echo "stage3: building xtfe with stage2 as the front end…"
stage_dir "$WORK/t2" "$WORK/xtfe2"
build_with "$WORK/t2" "$WORK/xtfe3" || { echo "stage3 FAILED"; exit 1; }

for s in 1 2 3; do
    printf 'stage%s  asm %s  %s lines\n' "$s" \
        "$(shasum -a 256 "$WORK/xtfe$s.s" | cut -c1-16)" \
        "$(wc -l < "$WORK/xtfe$s.s" | tr -d ' ')"
done

rc=0
if cmp -s "$WORK/xtfe2.s" "$WORK/xtfe3.s"; then
    echo "--- bootstrap: stage2 == stage3 — FIXED POINT ---"
else
    echo "--- bootstrap: stage2 != stage3 — NOT a fixed point ---"
    diff "$WORK/xtfe2.s" "$WORK/xtfe3.s" | head -20
    rc=1
fi
if cmp -s "$WORK/xtfe1.s" "$WORK/xtfe2.s"; then
    echo "--- bootstrap: stage1 == stage2 — the self-hosted front end matches the original ---"
else
    echo "--- bootstrap: stage1 != stage2 (the two front ends disagree somewhere) ---"
    diff "$WORK/xtfe1.s" "$WORK/xtfe2.s" | head -20
    rc=1
fi
exit $rc
