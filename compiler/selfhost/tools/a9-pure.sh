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
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
XC_HOST_ARCH=${XC_HOST_ARCH:-$( case "$(uname -m)" in (arm64|aarch64) echo arm64 ;; (*) echo x86_64 ;; esac )}
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/$XC_PLAT
[ -x "$BIN/xcc" ] || BIN=bin/linux
SRC=${1:-tests/asm-arm32/bare9.xc}
OUT=${2:-${SRC%.xc}.so}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# Through the xc compiler's own driver: front end, optimiser, back end,
# assembler and linker, all from selfhost/, with the arm9 runtime linked in
# (bug 574). This used to chain xtfe -> xtcg9 -> xtas9 by hand with no
# runtime and no dead-function pass; since 0.63 the class-name table keeps
# vtables alive, so every program references the runtime (`_xtc_dealloc`) and
# a runtime-free one-object link cannot load.
"$BIN/xcc-xc" -q -A arm9 -H . -o "$OUT" "$SRC"
echo "$OUT — front end, back end, assembler and linker all from selfhost/"
