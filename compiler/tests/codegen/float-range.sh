#!/bin/bash
# float-range.sh — the float-range pass (#23). xc defines an out-of-range
# float-to-integer conversion, and NaN, as 0, so the conversion carries a range
# check. When the optimiser proves the operand finite and in range it drops the
# check (`unchecked`, C's form). This program converts values the pass can
# prove (perlin's doubling octaves from `(float)(i % 2048) / 256`, a divide, a
# sum) and values it must leave checked (doubling past 2^32 over 40 trips, a
# negative to unsigned, NaN, a large i64 product). -O0 runs no optimiser, so
# every conversion keeps its check there: -O3 must print the same.
#
#   bash tests/codegen/float-range.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/fr.xc" <<'XC'
#import "Stdio.xc"

i32 main(void)
{
    u64 inr = (u64)0;
    u64 outr = (u64)0;
    for (u32 i in 0..(u32)65536)
    {
        float x = (float)(i % (u32)2048) / 256.0f;
        float y = (float)(i / (u32)2048) / 256.0f;
        for (u32 o in 0..4)
        {
            u32 xi = (u32)x;
            u32 yi = (u32)y;
            inr = inr + (u64)xi * (u64)3 + (u64)yi;
            x = x * 2.0f;
            y = y + y;
        }
        // Grows past 2^32 within 40 trips: must stay checked (0 once out).
        float z = 1.0f + (float)(i & (u32)7);
        for (u32 k in 0..40)
        {
            outr = outr + (u64)(u32)z;
            z = z * 2.0f;
        }
        // A negative value to unsigned: 0 under xc.
        float n = (float)(i % (u32)5) - 2.5f;
        outr = outr + (u64)(u32)n * (u64)7;
        // Signed and in range.
        i32 s = (i32)((float)(i % (u32)1000) - 500.0f);
        inr = inr + (u64)(i64)s;
    }
    float nan = 0.0f;
    nan = nan / nan;
    outr = outr + (u64)(u32)nan;
    Stdio.printf("%llu %llu\n", inr, outr);
    return 0;
}
XC
fail=0
"$XC" -q -O0 -o "$W/fr0" "$W/fr.xc" || { echo "FAIL: -O0 build"; exit 1; }
"$XC" -q -O3 -o "$W/fr3" "$W/fr.xc" || { echo "FAIL: -O3 build"; exit 1; }
a=$("$W/fr0"); b=$("$W/fr3")
if [ "$a" = "$b" ] && [ -n "$a" ]; then
    echo "  ok: -O0 and -O3 agree ($a)"
else
    echo "  FAIL: -O0 '$a' vs -O3 '$b'"
    fail=1
fi
[ $fail = 0 ] && echo "--- float-range: pass ---" || echo "--- float-range: FAIL ---"
exit $fail
