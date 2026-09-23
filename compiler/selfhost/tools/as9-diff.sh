#!/bin/bash
# as9-diff.sh — the ported ARM32 assembler against arm-none-eabi-as.
# =================================================================
#
# self-hosting M10. There is no ARM32 assembler in this project — the arm9 path
# shells out to gcc, which the device does not have — so this is the last
# capability gap between "the compiler runs on the A9" and "the A9 builds
# programs".
#
# The oracle is `as` itself: assemble the same `.s` both ways and compare the
# `.text` bytes. The subset is what the back end emits; anything outside it is
# reported by NAME (exit 3) rather than skipped, because an assembler that
# quietly drops an instruction produces an object that links and crashes.
#
# It used to assemble ONLY the six hand-written .s files in tests/asm-arm32 —
# curated, vendor-clean, and no measure of what the back end actually emits. It
# now compiles the WHOLE TREE through `xcc -A arm9 -S` and assembles that, the
# way as64/as68/asx86 do, so the subset under test is the instruction mix real
# programs produce rather than the one somebody thought to write down. The
# curated directory is still accepted as an argument.
#
#   bash selfhost/tools/as9-diff.sh              # the whole tree
#   bash selfhost/tools/as9-diff.sh <dir-of-.s>  # a directory of .s, as before

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
SRC=${1:-}
. "$(dirname "$0")/arm9-sysroot.sh"
WORK=${TMPDIR:-/tmp}/as9.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

command -v arm-none-eabi-as >/dev/null || {
    echo "!!! arm-none-eabi-as not on PATH — the oracle is absent, nothing was checked"
    exit 1
}

echo "building xtas9 (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtas9" selfhost/tools/xtas9.xc \
    -I selfhost/asm 2>&1 | grep -E "^[^ ].*error" && exit 1

pass=0; fail=0; unsup=0; oracle=0

# The .s files under test: a directory if one was named, else the whole tree
# compiled for arm9. SHARD_I/SHARD_N split the tree form across all-diff slots.
if [ -n "$SRC" ]; then
    LIST=$(ls "$SRC"/*.s 2>/dev/null)
else
    [ -n "$ARM9_SYSROOT" ] || {
        echo "--- as9-diff: BROKEN (no arm9 sysroot with a libc.so found)"
        echo "    set XTC_ARM9_SYSROOT=<loader build dir>; without it almost"
        echo "    nothing compiles for arm9 and almost nothing is compared."
        exit 1; }
    echo "arm9 sysroot: $ARM9_SYSROOT"
    LIST=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' \
           | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
fi

for src in $LIST; do
    case "$src" in
        *.s) f="$src" ;;
        *)   # Compile it for arm9 first. A file that will not build is an
             # ORACLE failure, named as such — it was never assembled, so it is
             # not a pass. 6502-only fixtures land here, as they should.
             if ! "$BIN/xcc" -A arm9 -H . -L "$ARM9_SYSROOT" -q -S \
                    -o "$WORK/src.s" "$src" >/dev/null 2>&1 || [ ! -s "$WORK/src.s" ]; then
                 oracle=$((oracle+1)); continue
             fi
             f="$WORK/src.s" ;;
    esac
    if ! arm-none-eabi-as -mcpu=cortex-a9 -mfpu=neon -o "$WORK/a.o" "$f" 2>/dev/null; then
        oracle=$((oracle+1)); continue
    fi
    arm-none-eabi-objcopy -O binary --only-section=.text "$WORK/a.o" "$WORK/a.bin"
    "$WORK/xtas9" "$f" --raw -o "$WORK/b.bin" >"$WORK/msg" 2>&1
    rc=$?
    if [ $rc -eq 3 ]; then
        unsup=$((unsup+1)); echo "  $(basename "$src") — $(sed 's/.*unsupported: //' "$WORK/msg")"
        continue
    fi
    if cmp -s "$WORK/a.bin" "$WORK/b.bin"; then pass=$((pass+1))
    else fail=$((fail+1)); echo "  $(basename "$src") differs"; fi
done
if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
    echo "--- as9-diff: BROKEN (0 files compared; $oracle oracle failures)"
    exit 1
fi
echo "--- as9-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
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

