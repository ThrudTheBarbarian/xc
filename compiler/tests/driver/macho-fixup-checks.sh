#!/bin/bash
# macho-fixup-checks.sh — the Mach-O link refuses a fixup that does not fit
# its instruction (#285). An 8-byte ldr through `sym@PAGEOFF` whose target is
# not 8-aligned used to be written with the low bits dropped, loading the
# wrong bytes; it is now a link error naming the symbol. The aligned form
# still links and runs. Through inline asm, where the pair reaches the link
# as written. (The branch range check needs a 128 MB image; not built here.)
#
#   bash tests/driver/macho-fixup-checks.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "macho-fixup-checks: skipped (macOS arm64 only)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
prog() { # $1 = the offset expression
cat <<XC
#import "Stdio.xc"
u8 gPad;
u64 gWord;
i32 main(void)
    {
    gWord = (u64)1234567;
    u64 v = (u64)0;
    asm
    {
        adrp x0, _gWord@PAGE
        ldr x1, [x0, $1]
        str x1, [v]
    }
    Stdio.printf("%llu\n", v);
    return 0;
    }
XC
}
prog "_gWord@PAGEOFF+1" > "$W/bad.xc"
prog "_gWord@PAGEOFF" > "$W/good.xc"
if "$XC" -q -O0 -H . -o "$W/bad" "$W/bad.xc" > "$W/e" 2>&1; then
    echo "FAIL macho-fixup-checks: a misaligned 8-byte @PAGEOFF load linked"; fail=1
elif ! grep -q "8-byte load or store through @PAGEOFF is not aligned to 'gWord'" "$W/e"; then
    echo "FAIL macho-fixup-checks: the refusal does not name the access and symbol: $(head -c 300 "$W/e")"; fail=1
fi
"$XC" -q -O0 -H . -o "$W/good" "$W/good.xc" > "$W/e" 2>&1 || { echo "FAIL macho-fixup-checks: the aligned load does not link: $(head -c 300 "$W/e")"; fail=1; }
[ -x "$W/good" ] && { got=$("$W/good"); [ "$got" = 1234567 ] || { echo "FAIL macho-fixup-checks: the aligned load reads '$got', want 1234567"; fail=1; }; }
[ $fail = 0 ] && echo "macho-fixup-checks: ok"
exit $fail
