#!/bin/bash
# elf-offsets.sh — an ELF file's offsets are read at their full width (#336).
# The ELF readers took a 64-bit e_shoff (and section offsets and sizes) as its
# low 32 bits, so an object whose section table is said to start past 4 GB was
# read from the truncated offset and linked as if nothing were wrong. Checked:
# an x86-64 object links, and the same object with e_shoff's high word set to 1
# is refused.
#
#   bash tests/driver/elf-offsets.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
[ -x "$XC" ] || { echo "FAIL elf-offsets: no compiler at $XC"; exit 1; }
ROOT=$(pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
printf 'u32 add3(u32 x) { return x + (u32)3; }\n' > "$W/lib.xc"
printf '#import "Stdio.xc"\nu32 add3(u32 x);\nvoid main(void) { Stdio.printf("%%u\\n", add3((u32)39)); return; }\n' > "$W/m.xc"
"$XC" -q -A x86_64 -H "$ROOT" -c -o "$W/lib.o" "$W/lib.xc" && "$XC" -q -A x86_64 -H "$ROOT" -c -o "$W/m.o" "$W/m.xc" \
    || { echo "FAIL elf-offsets: the objects do not build"; exit 1; }
"$XC" -q -A x86_64 -H "$ROOT" -o "$W/p" "$W/m.o" "$W/lib.o" > "$W/out" 2>&1 \
    || { echo "FAIL elf-offsets: the objects do not link: $(head -c 200 "$W/out")"; fail=1; }
# e_shoff is the 8 bytes at 40; its byte 44 is the low byte of the high word.
cp "$W/lib.o" "$W/bad.o"
printf '\001' | dd of="$W/bad.o" bs=1 seek=44 conv=notrunc 2> /dev/null
if "$XC" -q -A x86_64 -H "$ROOT" -o "$W/pbad" "$W/m.o" "$W/bad.o" > "$W/out" 2>&1; then
    echo "FAIL elf-offsets: an object whose section table starts past 4 GB was linked"; fail=1
fi
[ $fail = 0 ] && echo "elf-offsets: ok"
exit $fail
