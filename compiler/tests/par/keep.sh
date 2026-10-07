#!/bin/bash
# keep.sh — par's auto keeps what it learns (from 0.73), on this host's GPU.
#
# A block is run at a small size and a large one. The first run measures and
# saves a threshold in the program's settings store; the second decides
# without measuring; the user's own settings (par.<block> = cpu, or a number
# of items) override it. Nothing to compare where the host has no GPU.
#
#   bash tests/par/keep.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/keep.xc" <<'XC'
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"
#define BIG (1 << 22)
float v[BIG];
void step(u32 n)
    {
    par heavy
        {
        for (u32 i in 0..n)
            {
            float x = (float)i * 0.001f;
            v[i] = Math.sin(x) * Math.cos(x * 0.5f) + Math.sqrt(x + 1.0f);
            }
        }
    }
i32 main(void)
    {
    for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1) step((u32)2000);
    for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1) step((u32)BIG);
    Stdio.printf("done\n");
    return (i32)0;
    }
XC
"$XC" -q -H . -O2 "$W/keep.xc" -o "$W/keep" >"$W/build" 2>&1 || { echo "FAIL keep: build"; head -3 "$W/build"; exit 1; }
export XCC_SETTINGS_DIR="$W/st"; mkdir -p "$XCC_SETTINGS_DIR"
run() { XC_PAR_REPORT=1 "$W/keep" > "$W/$1" 2>&1; }
run r1
if ! grep -q "hardware key" "$W/r1" || grep -q "hardware key [0-9a-f]* (|" "$W/r1"; then
    echo "SKIP keep: no GPU on this host"; exit 0
fi
fail=0
conf="$W/st/keep.conf"
grep -q "^par.learned\..*\.heavy\..* = 2000,4194304$" "$conf" 2>/dev/null \
    || { echo "FAIL keep: first run did not learn CPU up to 2000, GPU from 4194304"; cat "$conf"; fail=1; }
run r2
if grep -q "learned\|auto picks\|auto keeps" "$W/r2"; then
    echo "FAIL keep: second run measured again"; grep "learned\|auto" "$W/r2"; fail=1
fi
[ "$(grep -c 'items on the GPU' "$W/r2")" = 4 ] || { echo "FAIL keep: second run did not put the large size on the GPU"; fail=1; }
cp "$conf" "$W/learned"
echo "par.heavy = cpu" >> "$conf"; run r3
grep -q "items on the GPU" "$W/r3" && { echo "FAIL keep: par.heavy = cpu still used the GPU"; fail=1; }
cp "$W/learned" "$conf"; echo "par = 3000000" >> "$conf"; run r4
[ "$(grep -c 'items on the GPU' "$W/r4")" = 4 ] || { echo "FAIL keep: par = 3000000 did not run only the large size on the GPU"; fail=1; }
grep -q "learned" "$W/r4" && { echo "FAIL keep: a user threshold still measured"; fail=1; }
[ $fail = 0 ] && echo "--- keep: pass ---"
exit $fail
