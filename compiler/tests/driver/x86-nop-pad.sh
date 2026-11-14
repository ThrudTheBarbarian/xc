#!/bin/bash
# x86-nop-pad.sh — x86-64 code is padded with multi-byte NOPs (#41). Both
# assemblers filled a .p2align in code with 0x90, one instruction per byte, and
# a loop head aligned to 64 can sit after a path that falls into its padding:
# sort_small's inner-loop exit ran 26 single-byte NOPs per outer trip. Now the
# padding is 0F 1F NOPs of up to 10 bytes. sort_small, one thread on Zen 5:
# 34.5G -> 30.0G instructions, 0.95 -> 0.86 s (clang 21: 31.3G, 0.72 s).
#
# Both drivers link sort_small for x86-64 Linux and win64 to the same bytes,
# the Linux binary has no run of more than one single-byte NOP, and on an
# x86-64 Linux host it gives its checksum.
#
#   bash tests/driver/x86-nop-pad.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../benchmark/src/sort_small.xc
[ -f "$SRC" ] || { echo "x86-nop-pad: no benchmark sources, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for t in x86_64 win64; do
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -A $t -O2 -H . -I ../benchmark/src -o "$W/$(basename "$c").$t" "$SRC" || { echo "FAIL $c -A $t: no binary"; fail=1; }
    done
    if [ -s "$W/xcc.$t" ] && [ -s "$W/xcc-xc.$t" ] && ! cmp -s "$W/xcc.$t" "$W/xcc-xc.$t"; then echo "FAIL: the two drivers' $t binaries differ"; fail=1; fi
done
OD=$(command -v llvm-objdump || command -v objdump || ls /opt/homebrew/opt/llvm/bin/llvm-objdump 2>/dev/null)
B="$W/$(basename "$XC").x86_64"
if [ -n "$OD" ] && [ -s "$B" ]; then
    run=$("$OD" -d --no-show-raw-insn "$B" 2>/dev/null | awk '/\tnop$/ {n++; if (n > m) m = n; next} {n = 0} END {print m + 0}')
    [ "$run" -le 1 ] || { echo "FAIL: $run single-byte NOPs in a row, want multi-byte padding"; fail=1; }
fi
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] && [ -s "$B" ]; then
    got=$(XC_PAR=cpu XC_PAR_THREADS=1 "$B" x 2>/dev/null | cut -d' ' -f1)
    [ "$got" = 615912388 ] || { echo "FAIL: sort_small gives $got, want 615912388"; fail=1; }
fi
[ $fail = 0 ] && echo "x86-nop-pad: ok"
exit $fail
