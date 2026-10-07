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
# Which device wins depends on the host (an integrated GPU can win even at
# 2000 items), so the test checks that what was learned is KEPT and USED, not
# which way it went: the first run must have saved bounds, and the second must
# put on the GPU exactly the runs those bounds send there, without measuring.
learned=$(grep "^par.learned\..*\.heavy\..* = " "$conf" 2>/dev/null | head -1)
[ -n "$learned" ] || { echo "FAIL keep: first run learned nothing"; cat "$conf" 2>/dev/null; fail=1; }
bounds=${learned##* = }; cpuUpTo=${bounds%,*}; gpuFrom=${bounds#*,}
want=0
for n in 2000 4194304; do
    if [ "$gpuFrom" != -1 ] && [ "$n" -ge "$gpuFrom" ] && { [ "$cpuUpTo" = -1 ] || [ "$n" -gt "$cpuUpTo" ]; }; then
        want=$((want + 4))
    fi
done
run r2
if grep -q "learned\|auto picks\|auto keeps" "$W/r2"; then
    echo "FAIL keep: second run measured again"; grep "learned\|auto" "$W/r2"; fail=1
fi
got=$(grep -c 'items on the GPU' "$W/r2")
[ "$got" = "$want" ] || { echo "FAIL keep: learned $bounds, so $want runs belong on the GPU; $got went there"; fail=1; }
cp "$conf" "$W/learned"
echo "par.heavy = cpu" >> "$conf"; run r3
grep -q "items on the GPU" "$W/r3" && { echo "FAIL keep: par.heavy = cpu still used the GPU"; fail=1; }
cp "$W/learned" "$conf"; echo "par = 3000000" >> "$conf"; run r4
[ "$(grep -c 'items on the GPU' "$W/r4")" = 4 ] || { echo "FAIL keep: par = 3000000 did not run only the large size on the GPU"; fail=1; }
grep -q "learned" "$W/r4" && { echo "FAIL keep: a user threshold still measured"; fail=1; }
[ $fail = 0 ] && echo "--- keep: pass ---"
exit $fail
