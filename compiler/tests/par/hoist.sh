#!/bin/bash
# hoist.sh — a par block's CPU loop reads its captures once (from 0.8.1).
#
# The body names a capture as an ivar of the block object, and a store in the
# loop keeps the hoister from moving any load, so every element reloaded every
# captured pointer from the object and the loop ran a third slower than the
# same loop over globals. run() now reads each capture into a local before the
# loop. The check is on the arm64 code, cross-compiled on any host: after the
# loop header no 64-bit load from the object (`ldr x, [x, #k]`) may remain,
# only the element loads and stores.
#
#   bash tests/par/hoist.sh
set -u
export XC_PAR_REMOTE=none     # discovery is on by default; this test names no daemon
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/hoist.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 n = (u32)4096;
    simd: u32* xs = new u32[n];
    simd: u32* ys = new u32[n];
    u32 k = (u32)3;
    for (u32 i in 0..n)
        {
        xs[i] = i;
        ys[i] = i;
        }
    par saxpy
        {
        for (u32 i in 0..n)
            ys[i] = k * xs[i] + ys[i];
        }
    Stdio.printf("%u\n", ys[n - (u32)1]);
    return (i32)0;
    }
XC
# The arm64 code: the host's own target on a Mac, and Android's elsewhere
# (the same back end; the macOS support tree imports frameworks a Linux
# host cannot see).
ARCH=$( [ "$(uname -s)" = Darwin ] && echo arm64 || echo android )
"$XC" -q -H . -O2 -A $ARCH -S -o "$W/hoist.s" "$W/hoist.xc" >"$W/build" 2>&1 || { echo "FAIL hoist: build"; head -3 "$W/build"; exit 1; }
# run() from its first loop label to its return.
# (Mach-O spells the symbol _ParImpl$0$run, ELF spells it without the underscore.)
awk '/^_?ParImpl\$0\$run:/{on=1} on && /_bb_1_for_header:/{loop=1} on && loop{print} on && /^[[:space:]]*ret$/{exit}' "$W/hoist.s" > "$W/loop.s"
[ -s "$W/loop.s" ] || { echo "FAIL hoist: no par loop in the arm64 output"; exit 1; }
reloads=$(grep -cE '^\s*ldr\s+x[0-9]+,\s*\[x[0-9]+(,\s*#[0-9]+)?\]' "$W/loop.s")
if [ "$reloads" != 0 ]; then
    echo "FAIL hoist: $reloads 64-bit loads inside the par loop (captures reloaded):"
    grep -nE '^\s*ldr\s+x[0-9]+,' "$W/loop.s" | head -4
    exit 1
fi
echo "PASS hoist"
