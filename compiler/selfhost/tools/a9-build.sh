#!/bin/bash
# a9-build.sh — an xtc program to an arm9 .so, through the PORTED tools.
# =================================================================
#
# self-hosting M11. Every step below the link is the port's own:
#
#   source ──xtfe──▶ IR ──xtcg9──▶ .s ──xtas9──▶ .o ──ld──▶ .so
#
# Only the final link is still the GNU toolchain's; the linker is the next
# piece. The .o that goes into it is written by `selfhost/asm/Elf32.xc` from
# bytes `selfhost/asm/Arm32.xc` encoded, and the assembly is what
# `selfhost/codegen/Arm9.xc` emitted from IR `selfhost/ir/IrParse.xc` read.
#
#   bash selfhost/tools/a9-build.sh <prog.xc> [out.so]
#
# The point is not speed, it is that the chain has no hole in it: run the
# result under the XTOS loader and it prints what the reference build prints.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -eu
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
SRC=${1:?usage: a9-build.sh <prog.xc> [out.so]}
OUT=${2:-${SRC%.xc}.so}
SYSROOT=${XTC_ARM9_SYSROOT:-}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

INCS=(-I support/generic/lib -I support/arm9/lib)

echo "building the ported tools…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$W/xtfe"  selfhost/tools/xtfe.xc -I selfhost/driver \
    -I support/generic/lib -I support/arm64/lib -I support/xt6502/lib \
    -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema \
    -I selfhost/ir >/dev/null
"$BIN/xcc" -O2 -A arm64 -H . -o "$W/xtcg9" selfhost/tools/xtcg9.xc \
    -I selfhost/ir -I selfhost/codegen >/dev/null
"$BIN/xcc" -O2 -A arm64 -H . -o "$W/xtas9" selfhost/tools/xtas9.xc \
    -I selfhost/asm >/dev/null

echo "front end  → IR"
# The ported front end has no DWARF reader, so a program that reaches libc
# through `#import <c>` is beyond it — say so and fall back, rather than
# quietly using the original and calling the chain complete.
if ! "$W/xtfe" -m arm9 -H . "${INCS[@]}" -L "$SYSROOT" "$SRC" -o "$W/a.ir" 2>"$W/feerr"; then
    echo "  !! ported front end: $(sed 's/.*unsupported: /unsupported: /' "$W/feerr" | head -1)"
    echo "  !! falling back to xcc-fe for THIS STEP — the rest of the chain is the port's"
    "$BIN/xcc-fe" -m arm9 -H . "${INCS[@]}" -L "$SYSROOT" "$SRC" -o "$W/a.ir" >/dev/null
fi
echo "back end   → A32 assembly"
"$W/xtcg9" "$W/a.ir" -o "$W/a.s"
# The xtc entry gives up the name `main` to the C stub, which records argc/argv
# — the same rename the driver does before it assembles.
python3 - "$W/a.s" "$W/b.s" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
out = []
for line in open(src):
    if any(k in line for k in ('.ascii', '.asciz', '.string')):
        out.append(line)
    else:
        out.append(re.sub(r'\bmain\b', 'xt_main', line))
open(dst, 'w').write(''.join(out))
PY
echo "assembler  → ELF object"
"$W/xtas9" "$W/b.s" -o "$W/a.o"

# The per-program C stub (ARC/heap runtime + the real `main`) still comes from
# the driver, so ask it to build the same program and borrow the stub it wrote.
"$BIN/xcc" -O0 -A arm9 -H . -o "$W/ref.so" "$SRC" "${INCS[@]}" -L "$SYSROOT" >/dev/null 2>&1 || true
STUB=$(find "${TMPDIR:-/tmp}" /var/folders -name "xtc-arm9-pic-stub.c" -newer "$W/a.o" 2>/dev/null | head -1)
[ -n "$STUB" ] || STUB=$(find "${TMPDIR:-/tmp}" /var/folders -name "xtc-arm9-pic-stub.c" 2>/dev/null | head -1)

echo "link       → $OUT"
arm-none-eabi-gcc -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=vfpv3 \
    -fPIC -shared -nostdlib -Wl,-Bsymbolic \
    "$W/a.o" support/arm9/runtime/libxt-pic.c "$STUB" -lgcc \
    -L "$SYSROOT" -lc -o "$OUT"
echo "done: $OUT"
