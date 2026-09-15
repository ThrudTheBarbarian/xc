#!/bin/bash
# a9-pure.sh — source to a running A9 program with NOTHING but the port.
# =================================================================
#
# self-hosting M12. Every step is xtc code written in this tree:
#
#   source ──xtfe──▶ IR ──xtcg9──▶ .s ──xtas9 --shared──▶ .so
#
# No arm-none-eabi-gcc, no as, no ld, and no xcc-fe. The program has to be
# self-contained for that to hold — no libc, no heap, no ARC — because the
# linker takes one object and there is no C runtime to link against. That is
# the honest boundary of what is finished, and `tests/asm-arm32/bare9.xc` is a
# program that lives inside it.
#
#   bash selfhost/tools/a9-pure.sh [prog.xc] [out.so]

set -eu
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
SRC=${1:-tests/asm-arm32/bare9.xc}
OUT=${2:-${SRC%.xc}.so}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

"$BIN/xcc" -O2 -A arm64 -H . -o "$W/xtfe"  selfhost/tools/xtfe.xc -I selfhost/driver \
    -I support/generic/lib -I support/arm64/lib -I support/xt6502/lib \
    -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema \
    -I selfhost/ir >/dev/null
"$BIN/xcc" -O2 -A arm64 -H . -o "$W/xtcg9" selfhost/tools/xtcg9.xc \
    -I selfhost/ir -I selfhost/codegen >/dev/null
"$BIN/xcc" -O2 -A arm64 -H . -o "$W/xtas9" selfhost/tools/xtas9.xc \
    -I selfhost/asm >/dev/null

"$W/xtfe"  -m arm9 -H . -I support/arm9/lib -I support/generic/lib "$SRC" -o "$W/a.ir"
"$W/xtcg9" "$W/a.ir" -o "$W/a.s"
"$W/xtas9" "$W/a.s" --shared -o "$OUT"
echo "$OUT — front end, back end, assembler and linker all from selfhost/"
