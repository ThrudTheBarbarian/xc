#!/bin/bash
# serial-outline.sh — a loop marked `: serial` is never run in parallel, even
# by the IR outliner (XC_PAR_PROPOSE=outline), which once outlined it into a
# block that ran on the GPU (#727). The marked loop stays a loop; the one
# beside it, unmarked, still becomes a block; the answer is the serial one.
#
#   bash tests/driver/serial-outline.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/s.xc" <<'SRC'
#import "Stdio.xc"
#import "Par.xc"
#define N 1000003
float xs[N];
float ys[N];
i32 main(void)
{
    for (u32 i = 0; i < N; i++) : serial
        xs[i] = (float)(i % 97);
    for (u32 i = 0; i < N; i++)
        ys[i] = xs[i] * 2.0 + 1.0;
    float s = 0.0;
    for (u32 i = 0; i < N; i++) : serial
        s = s + ys[i];
    Stdio.printf("%.1f\n", s);
    return 0;
}
SRC
fail=0
XC_PAR_PROPOSE=outline XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O2 -H . --par-style=cpu -o "$W/s" "$W/s.xc" > "$W/t" 2>&1 \
    || { echo "FAIL serial-outline: no build: $(head -c 300 "$W/t")"; exit 1; }
grep -qE "^outline: main:8: outlined, a block" "$W/t" && { echo "FAIL serial-outline: the loop marked serial became a block"; fail=1; }
grep -qE "^outline: main:12: outlined, a block" "$W/t" && { echo "FAIL serial-outline: the second loop marked serial became a block"; fail=1; }
grep -qE "^outline: main:10: outlined, a block" "$W/t" || { echo "FAIL serial-outline: the unmarked loop did not become a block"; grep '^outline:' "$W/t" | head -4; fail=1; }
got=$(XC_PAR=cpu "$W/s")
[ "$got" = "96989752.0" ] || { echo "FAIL serial-outline: '$got', wanted 96989752.0"; fail=1; }
[ $fail = 0 ] && echo "--- serial-outline: pass ---"
exit $fail
