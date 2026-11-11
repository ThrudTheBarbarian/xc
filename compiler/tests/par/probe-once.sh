#!/bin/bash
# probe-once.sh — the probe measures a block to the end on its first run
# (#148): under XC_PAR_PROBE=1 a block that runs once per program run (here
# in main, outside every loop: the compiler marks it runsOnce) is measured by
# auto to the end on that run, on copies of it with the arrays it writes put
# back after each, and auto's choice is saved; the next run places it without
# measuring. Without the probe one run cannot finish measuring it. The array
# it writes and its reduction are the same with and without the probe, and
# as XC_PAR=cpu gives them (integer arithmetic, so every device must agree
# exactly). Self-hosted compiler only; skipped where no
# device but the CPU is found (auto then has nothing to measure).
#
#   bash tests/par/probe-once.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/once.xc" <<'XC'
#use "Stdio.xc"
#use "Par.xc"
#define N (1 << 22)
i32 main(void)
{
    u32* a = new u32[N];
    u32* b = new u32[N];
    for (u32 i = 0; i < N; i++) { a[i] = i % 977; b[i] = 1; }
    u64 total = 0;
    par once :reduce(+ total)
        {
        for (u32 i in 0..N)
            {
            u32 x = a[i];
            u32 k = 0;
            while (k < 64 && x < 4000) { x = x * 3 / 2 + 7; k = k + 1; }
            b[i] = b[i] + x;
            total = total + k;
            }
        }
    u64 s = 0;
    for (u32 i = 0; i < N; i++) s = s + b[i];
    printf("%llu %llu\n", total, s);
    return 0;
}
XC
"$XC" -q -O3 -H . -o "$W/once" "$W/once.xc" > "$W/b" 2>&1 || { echo "FAIL probe-once: does not build"; head -3 "$W/b"; exit 1; }
want=$(XC_PAR=cpu XCC_SETTINGS_DIR="$W/s0" "$W/once")
# Without the probe: one run, nothing learned for the block.
XCC_SETTINGS_DIR="$W/s1" XC_PAR_REPORT=1 "$W/once" > "$W/o1" 2> "$W/e1"
if ! grep -q 'items on the GPU' "$W/o1" "$W/e1"; then
    echo "--- probe-once: skipped (no GPU found) ---"
    exit 0
fi
[ "$(grep -v '^par:' "$W/o1")" = "$want" ] || { echo "FAIL probe-once: a plain run gives '$(grep -v '^par:' "$W/o1")', the CPU '$want'"; fail=1; }
grep -qs '^par\.learned\..*\.once\.' "$W/s1"/*.conf && { echo "FAIL probe-once: one plain run already learned the block (the test no longer shows the probe's work)"; fail=1; }
# With the probe: measured to the end, learned, the same results.
XCC_SETTINGS_DIR="$W/s2" XC_PAR_PROBE=1 XC_PAR_REPORT=1 "$W/once" > "$W/o2" 2> "$W/e2"
[ "$(grep -v '^par:' "$W/o2")" = "$want" ] || { echo "FAIL probe-once: the probe run gives '$(grep -v '^par:' "$W/o2")', the CPU '$want'"; fail=1; }
grep -q 'probe: once: auto measured it to the end in [0-9]* runs (it runs once per program run)' "$W/o2" "$W/e2" \
    || { echo "FAIL probe-once: the probe did not measure the block to the end, or did not know it runs once:"; grep -h 'probe: once' "$W/o2" "$W/e2" | grep -v 'tiles of' | head -4; fail=1; }
grep -qs '^par\.learned\..*\.once\.' "$W/s2"/*.conf || { echo "FAIL probe-once: nothing learned for the block after the probe run"; fail=1; }
# The next run: placed from what was learned, no measuring.
XCC_SETTINGS_DIR="$W/s2" XC_PAR_REPORT=1 "$W/once" > "$W/o3" 2> "$W/e3"
[ "$(grep -v '^par:' "$W/o3")" = "$want" ] || { echo "FAIL probe-once: the run after the probe gives '$(grep -v '^par:' "$W/o3")', the CPU '$want'"; fail=1; }
grep -q 'auto picks\|probe:' "$W/o3" "$W/e3" && { echo "FAIL probe-once: the run after the probe measured again:"; grep -h 'auto picks\|probe:' "$W/o3" "$W/e3" | head -3; fail=1; }
[ $fail = 0 ] && echo "--- probe-once: pass ---" || echo "--- probe-once: FAIL ---"
exit $fail
