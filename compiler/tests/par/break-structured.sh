#!/bin/bash
# break-structured.sh — a `break` out of a loop in a par block keeps the GPU
# kernel structured (#404). The edge a `break` takes leaves the loop through
# a block of its own, so the loop had two exits and the Metal printer fell
# back to the `while (pc) switch (pc)` dispatch loop: right answers, many
# times slower. Now a loop whose other exits only pass control on to its
# exit is printed with `break`. Three blocks: a for-in loop with a break, a
# break out of an inner loop, and a break that carries a value out. Their
# kernels have no dispatch loop, and the GPU and the CPU give the answers a
# plain loop gives. macOS only (the kernels are read as Metal).
#
#   bash tests/par/break-structured.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
if [ "$(uname -s)" != Darwin ]; then
    echo "--- break-structured: skipped (Metal only) ---"
    exit 0
fi
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/brk.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
float gA[4096];
u32 gN[4096];
i32 gV[4096];
i32 main(i32 argc, u8** argv) {
    u32 n = 64;
    par a :grid(n, n) {
        float t = 0.0;
        for (u32 i in 0..100) {
            t = t + 0.5;
            if (t > (float)par.x) { break; }
        }
        gA[par.y * par.width + par.x] = t;
    }
    par nest :grid(n, n) {
        u32 s = 0;
        for (u32 i in 0..8) {
            for (u32 j in 0..50) {
                s = s + j;
                if (j >= par.x + i) { break; }
            }
        }
        gN[par.y * par.width + par.x] = s;
    }
    par val :grid(n, n) {
        i32 found = -1;
        for (u32 i in 0..40) {
            if ((i * 7 + par.y) % 64 == par.x) { found = (i32)i; break; }
        }
        gV[par.y * par.width + par.x] = found;
    }
    u32 bad = 0;
    for (u32 y = 0; y < n; y = y + 1) {
        for (u32 x = 0; x < n; x = x + 1) {
            float t = 0.0;
            u32 i = 0;
            while (i < 100) {
                t = t + 0.5;
                i = i + 1;
                if (t > (float)x) { i = 100; }
            }
            u32 s = 0;
            for (u32 k = 0; k < 8; k = k + 1) {
                u32 j = 0;
                while (j < 50) {
                    s = s + j;
                    if (j >= x + k) { j = 50; } else { j = j + 1; }
                }
            }
            i32 found = -1;
            for (u32 q = 0; q < 40; q = q + 1)
                if (found < 0 && (q * 7 + y) % 64 == x) found = (i32)q;
            u32 at = y * n + x;
            if (gA[at] != t) bad = bad + 1;
            if (gN[at] != s) bad = bad + 1;
            if (gV[at] != found) bad = bad + 1;
        }
    }
    Stdio.printf("%u\n", bad);
    Stdio.printf("%s %s %s\n", ((String*)Par.ranOn("a").get(0)).cString(),
        ((String*)Par.ranOn("nest").get(0)).cString(), ((String*)Par.ranOn("val").get(0)).cString());
    return 0;
}
XC
"$XC" -q -O2 -H . -o "$W/brk" "$W/brk.xc" > "$W/b" 2>&1 \
    || { echo "FAIL break-structured: does not build (exit $?)"; tail -3 "$W/b"; exit 1; }
for g in gA gN gV; do
    strings "$W/brk" | grep -q "^// xcpar msl .*glob=$g:" \
        || { echo "FAIL break-structured: no Metal kernel writes $g"; fail=1; }
done
if strings "$W/brk" | grep -q 'switch (pc)'; then
    echo "FAIL break-structured: a kernel is printed as the dispatch loop"; fail=1
fi
# The WGSL printer walks the same plan.
"$XC" -q -O2 -H . -fpar-kernels=all -o "$W/all" "$W/brk.xc" > "$W/b" 2>&1 \
    || { echo "FAIL break-structured: does not build with -fpar-kernels=all"; tail -3 "$W/b"; fail=1; }
if strings "$W/all" | grep -q 'switch pc'; then
    echo "FAIL break-structured: a WGSL kernel is printed as the dispatch loop"; fail=1
fi
for m in cpu gpu; do
    got=$(XC_PAR=$m XCC_SETTINGS_DIR="$W/s$m" "$W/brk" 2>/dev/null)
    [ "$(printf '%s\n' "$got" | head -1)" = 0 ] \
        || { echo "FAIL break-structured: XC_PAR=$m gives $(printf '%s' "$got" | head -1) wrong cells"; fail=1; }
    on=$(printf '%s\n' "$got" | sed -n 2p)
    if [ $m = gpu ]; then
        case "$on" in metal:*metal:*metal:*) ;; *) echo "FAIL break-structured: XC_PAR=gpu ran on '$on'"; fail=1 ;; esac
    fi
done
[ $fail = 0 ] && echo "--- break-structured: passed ---"
exit $fail
