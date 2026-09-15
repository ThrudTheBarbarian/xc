#!/usr/bin/env bash
# asm-arm32/run.sh — the in-house ARM32 assembler against arm-none-eabi-as.
#
# `xcc -A arm9 -c` assembles with XAArm32Assembler and writes the object with
# XTElf32Writer, so that no host needs a cross-toolchain to produce arm9 code —
# not a Windows box, and not the Cortex-A9 itself, which has no gcc. This is the
# check that the bytes are the SAME bytes gcc's assembler would have produced.
#
# Two corpora, and the second is the one that matters:
#
#   1. tests/asm-arm32/*.s — hand-written, one file per instruction family.
#      Cheap, and it pins each encoding to a form a human chose.
#   2. Every fixture, compiled to `.s` and assembled both ways. This is what
#      found the real gaps: `vld1.8`/`vst1.8` (every struct copy), the NEON
#      integer set (the whole auto-vectoriser) and the atomics
#      (`dmb`/`ldrexh`/`strexh`, every threaded program) were all missing from
#      the subset while corpus 1 read 4/4 — green because nothing exercised
#      them, which is this project's most persistent trap.
#
# The oracle's absence is reported LOUDLY and exits non-zero: an assembler
# compared against nothing is not an assembler that agrees with anything.
#
#   bash tests/asm-arm32/run.sh [n-fixtures]     (default: all)
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XCC="bin/osx/xcc"; LN="bin/osx/xcc-ln-arm9"
[ -x "$XCC" ] || { XCC="bin/linux/xcc"; LN="bin/linux/xcc-ln-arm9"; }
SR="${XTC_ARM9_SYSROOT:-}"
LIMIT="${1:-0}"

command -v arm-none-eabi-as >/dev/null || {
    echo "!!! arm-none-eabi-as is not on PATH — the oracle is absent, NOTHING was checked"
    exit 1
}
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0

# Compare one .s file, assembled both ways, by its .text bytes.
cmp_one() {   # <file> <label> <extra-as-flags…>
    local f="$1" label="$2"; shift 2
    arm-none-eabi-as -mcpu=cortex-a9 -mfpu=neon "$@" -o "$W/a.o" "$f" 2>/dev/null || return 2
    arm-none-eabi-objcopy -O binary --only-section=.text "$W/a.o" "$W/a.bin"
    "$LN" --object "$f" "$W/b.o" 2>"$W/err" || {
        echo "  UNSUPPORTED $label: $(sed 's/.*assembly: //' "$W/err" | head -1)"; return 3
    }
    arm-none-eabi-objcopy -O binary --only-section=.text "$W/b.o" "$W/b.bin"
    cmp -s "$W/a.bin" "$W/b.bin" && return 0
    echo "  DIFFERS $label at $(cmp "$W/a.bin" "$W/b.bin" 2>&1 | head -1)"
    return 1
}

echo "--- hand-written encodings ---"
hp=0; hf=0
for f in tests/asm-arm32/*.s; do
    cmp_one "$f" "$(basename "$f")" && hp=$((hp+1)) || { hf=$((hf+1)); fail=1; }
done
echo "    identical=$hp not-identical=$hf"

echo "--- every fixture, as the back end actually emits it ---"
p=0; d=0; u=0; o=0; n=0
for src in tests/fixtures/*.xc; do
    [ "$LIMIT" != 0 ] && [ "$n" -ge "$LIMIT" ] && break
    "$XCC" -q -A arm9 -L "$SR" -S -o "$W/t.s" "$src" 2>/dev/null || continue
    n=$((n+1))
    cmp_one "$W/t.s" "$(basename "$src" .xc)" -mfloat-abi=softfp
    case $? in
        0) p=$((p+1)) ;;
        1) d=$((d+1)); fail=1 ;;
        2) o=$((o+1)) ;;                 # the ORACLE could not assemble it
        3) u=$((u+1)); fail=1 ;;         # outside our subset — a gap, not a pass
    esac
done
echo "    identical=$p differs=$d unsupported=$u oracle-failed=$o"
echo "--- asm-arm32: $([ $fail -eq 0 ] && echo ALL IDENTICAL || echo FAILURES) ---"
exit $fail
