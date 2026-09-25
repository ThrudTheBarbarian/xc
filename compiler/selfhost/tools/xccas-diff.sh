#!/bin/bash
# xccas-diff.sh — the xc assembler against the reference xcc-as, as a user runs it.
# =================================================================
#
# xta-diff proves the two assemblers agree on what the compiler hands them.
# This proves the COMMAND LINE agrees: every option, every output format, and
# every diagnostic. Each run happens twice, once per assembler, in identical
# copies of a directory, and the whole outcome is compared — stdout, stderr,
# the exit status, and every file the run wrote.
#
#   1. tests/xcc-as/cases.txt — one invocation per line over the fixtures there:
#      layouts, symbol files, -D, listings, PRG, the error paths.
#   2. The opcode table: every mnemonic in every operand form, then again with
#      only the forms that exist, so the encodings are compared as well as the
#      refusals.
#   3. Every .asm in the tree, plain and banked through the xt layout, with a
#      listing.
#
#   bash selfhost/tools/xccas-diff.sh [pattern]     # `cases` or `opcodes` runs one part

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
ROOT=$(pwd)
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/xccasdiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
VERSION=$(tr -d ' \n' < VERSION)

echo "building xcc-as (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -DXCC_VERSION="\"$VERSION\"" -o "$WORK/xcc-as" \
    selfhost/tools/xta6502.xc -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xcc-as" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi
REF="$ROOT/$BIN/xcc-as"
PORT="$WORK/xcc-as"
FIX=tests/xcc-as
XT_LNK="$ROOT/support/xt6502/layouts/xt.lnk"

pass=0; fail=0
declare -a FAILED

# run_both LABEL SRC-DIR [env:NAME=VALUE] ARGS... — run both assemblers in
# fresh copies of SRC-DIR and compare everything.
run_both() {
    local label=$1 src=$2; shift 2
    local envset=()
    if [ $# -gt 0 ] && [[ "$1" == env:* ]]; then envset=("${1#env:}"); shift; fi
    local side tool
    for side in ref port; do
        tool=$REF; [ "$side" = port ] && tool=$PORT
        rm -rf "$WORK/$side"
        cp -R "$src" "$WORK/$side"
        ( cd "$WORK/$side" && env ${envset[@]+"${envset[@]}"} "$tool" "$@" \
            > "$WORK/$side.out" 2> "$WORK/$side.err"; echo $? > "$WORK/$side.rc" )
    done
    local why=""
    cmp -s "$WORK/ref.rc" "$WORK/port.rc"   || why="exit $(cat "$WORK/ref.rc") vs $(cat "$WORK/port.rc")"
    [ -z "$why" ] && { cmp -s "$WORK/ref.out" "$WORK/port.out" || why="stdout differs"; }
    [ -z "$why" ] && { cmp -s "$WORK/ref.err" "$WORK/port.err" || why="stderr: $(diff "$WORK/ref.err" "$WORK/port.err" | grep '^[<>]' | head -2 | tr '\n' ' ')"; }
    [ -z "$why" ] && { diff -rq "$WORK/ref" "$WORK/port" > "$WORK/tree.diff" 2>&1 || why="output: $(head -1 "$WORK/tree.diff")"; }
    if [ -z "$why" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); FAILED+=("$label ($why)")
    fi
}

# ── 1. The command-line cases ────────────────────────────────────────
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == \#* ]] && continue
    [ -n "$PATTERN" ] && [ "$PATTERN" != cases ] && [[ "$line" != *"$PATTERN"* ]] && continue
    read -r -a args <<< "$line"
    for k in "${!args[@]}"; do args[$k]=${args[$k]//@SUPPORT@/$ROOT/support}; done
    run_both "case '$line'" "$FIX" ${args[@]+"${args[@]}"}
done < "$FIX/cases.txt"

# ── 2. The opcode table ──────────────────────────────────────────────
MNEMS="ADC ADD AND ASL BCC BCS BEQ BIT BMI BNE BPL BRA BRK BVC BVS CLC CLD CLI CLV CMP CPX CPY DEC DEX DEY EOR INC INX INY JMP JSR LDA LDX LDY LSR NOP ORA PHA PHP PHX PHY PLA PLL PLP PLX PLY PSH ROL ROR RTI RTS SBC SEC SED SEI STA STX STY TAX TAY TSX TXA TXS TYA"
FORMS=("" "A" '#$12' '$12' '$12,X' '$12,Y' '$1234' '$1234,X' '$1234,Y' '($12,X)' '($12),Y' '($1234)'
       '+5,SP' '-3,SP,X' '(+2,SP),Y' 'SP,#-4' 'target')
if [ -z "$PATTERN" ] || [[ "opcodes" == *"$PATTERN"* ]]; then
    mkdir -p "$WORK/ops"
    for fi in "${!FORMS[@]}"; do
        f="$WORK/ops/form$fi.asm"
        { echo "        .org \$2000"; echo "target:"
          for m in $MNEMS; do echo "        $m ${FORMS[$fi]}"; done; } > "$f"
        run_both "opcodes form '${FORMS[$fi]}'" "$WORK/ops" "form$fi.asm" -l "form$fi.lst"
        # The same form with only the mnemonics that have it, so the bytes
        # are compared too.
        bad=$(cd "$WORK/ops" && "$REF" "form$fi.asm" -o /dev/null 2>&1 | sed -n 's/.*error: line \([0-9]*\):.*/\1/p' | tr '\n' ' ')
        awk -v bad=" $bad " 'index(bad, " " NR " ") == 0' "$f" > "$WORK/ops/valid$fi.asm"
        run_both "opcodes form '${FORMS[$fi]}' (valid)" "$WORK/ops" "valid$fi.asm" -l "valid$fi.lst"
    done
    rm -rf "$WORK/ops"
fi

# ── 3. Every .asm in the tree ────────────────────────────────────────
mkdir -p "$WORK/empty"
FILES=$(find tests support -name '*.asm' -not -path 'tests/xcc-as/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    [ "$PATTERN" = cases ] || [ "$PATTERN" = opcodes ] && continue
    run_both "$f" "$WORK/empty" "$ROOT/$f" -I "$ROOT" -I "$ROOT/support" -o out.xex
    run_both "$f (banked)" "$WORK/empty" "$ROOT/$f" -L "$XT_LNK" -I "$ROOT" -I "$ROOT/support" -o out.xex -l out.lst
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- xccas-diff: pass=$pass fail=$fail ---"
[ "$fail" -eq 0 ] || exit 1
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
