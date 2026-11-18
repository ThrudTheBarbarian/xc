#!/bin/bash
# macho-fixup-checks.sh — the Mach-O link refuses a fixup that does not fit
# its instruction (#285). An 8-byte ldr through `sym@PAGEOFF+1` (here from a
# C function's inline asm, which clang's object carries with its addend) was
# written with the low bits dropped, so the program read the symbol itself
# and printed 1234567 as if nothing were wrong; the link is now refused,
# naming the access and the symbol. The aligned load still links and runs.
# (The branch range check needs a 128 MB image; not built here.)
#
#   bash tests/driver/macho-fixup-checks.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "macho-fixup-checks: skipped (macOS arm64 only)"; exit 0; }
command -v clang > /dev/null || { echo "macho-fixup-checks: skipped (no clang)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
prog() { # $1 = the page offset expression
cat <<C
#include <stdio.h>
unsigned char gPad;
unsigned long long gWord = 1234567;
__attribute__((noinline)) unsigned long long peek(void)
{
    unsigned long long v;
    __asm__ volatile("adrp x9, _gWord@PAGE\n\tldr %0, [x9, $1]" : "=r"(v) : : "x9");
    return v;
}
int main(void) { printf("%llu\n", peek()); return 0; }
C
}
prog "_gWord@PAGEOFF+1" > "$W/bad.c"
prog "_gWord@PAGEOFF" > "$W/good.c"
if "$XC" -q -O2 -o "$W/bad" "$W/bad.c" > "$W/e" 2>&1; then
    echo "FAIL macho-fixup-checks: a misaligned 8-byte @PAGEOFF load linked"; fail=1
elif ! grep -q "a load or store of 8 bytes through @PAGEOFF is not aligned to 'gWord'" "$W/e"; then
    echo "FAIL macho-fixup-checks: the refusal does not name the access and symbol: $(head -c 300 "$W/e")"; fail=1
fi
"$XC" -q -O2 -o "$W/good" "$W/good.c" > "$W/e" 2>&1 || { echo "FAIL macho-fixup-checks: the aligned load does not link: $(head -c 300 "$W/e")"; fail=1; }
[ -x "$W/good" ] && { got=$("$W/good"); [ "$got" = 1234567 ] || { echo "FAIL macho-fixup-checks: the aligned load reads '$got', want 1234567"; fail=1; }; }
[ $fail = 0 ] && echo "macho-fixup-checks: ok"
exit $fail
