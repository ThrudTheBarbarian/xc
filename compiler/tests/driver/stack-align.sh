#!/bin/bash
# stack-align.sh — a large local or global array starts on a 64-byte boundary
# on x86-64
# (2026-10-28). rbp is only 16-aligned and the stack's place moves from run
# to run, so the vector loops over a local array split every 64-byte load
# across two cache lines in three runs of four: array_sum ran 213 or 380 ms
# and mem_copy 350 or 510 from the same binary (perf: 1.8 G split loads in a
# slow run, a few thousand in a fast one). The array's slot has 64 bytes of
# slack and its address is rounded up into it. Both compilers print the same
# code; on an x86-64 host (or XTC_X86_HOST over ssh) the array's address is a
# multiple of 64 in every run. A global array of 256 bytes or more is
# 64-aligned too (it sat 40 bytes into a cache line, every load split).
#
#   [XTC_X86_HOST=<host>] bash tests/driver/stack-align.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/al.xc" <<'XC'
#import "Stdio.xc"

u8 gpad[3];
u32 g[1024];

i32 main(i32 argc, u8** argv)
{
    u32 a[1024];
    u8 small[16];
    for (u32 i = 0; i < 1024; i = i + 1)
        a[i] = i + (u32)argc;
    small[0] = (u8)argc;
    u32 s = 0;
    for (u32 i = 0; i < 1024; i = i + 1)
        s = s + a[i];
    g[5] = s;
    gpad[0] = (u8)argc;
    Stdio.printf("%u %u %u\n", (u32)(((u64)(pointer)&a[0]) & (u64)63), s + (u32)small[0] + (u32)gpad[0] - (u32)argc,
                 (u32)(((u64)(pointer)&g[0]) & (u64)63) + g[5] - s);
    return 0;
}
XC
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -S -o "$W/$(basename "$c").s" "$W/al.xc" || { echo "FAIL $c: no assembly"; fail=1; }
done
S="$W/$(basename "$XC").s"
grep -qE 'and[[:space:]]+rax, -64' "$S" || { echo "FAIL stack-align: the array's address is not rounded to 64"; fail=1; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL stack-align: the two compilers' code differs"; fail=1; fi
run() { :; }
H=${XTC_X86_HOST:-}
if [ "$(uname -m)" = x86_64 ] && [ "$PLAT" = linux ]; then
    "$XC" -q -O2 -o "$W/al" "$W/al.xc" || { echo "FAIL: does not build"; exit 1; }
    run() { for i in 1 2 3 4 5 6 7 8; do "$W/al"; done; }
elif [ -n "$H" ]; then
    "$XC" -q -A x86_64 -O2 -o "$W/al" "$W/al.xc" || { echo "FAIL: does not build for x86-64"; exit 1; }
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    scp $SSHO -q "$W/al" "$H:stack-align.bin" || { echo "FAIL: copy to $H"; exit 1; }
    run() { ssh $SSHO "$H" 'for i in 1 2 3 4 5 6 7 8; do ./stack-align.bin; done; rm -f stack-align.bin'; }
fi
out=$(run)
if [ -n "$out" ]; then
    bad=$(printf '%s\n' "$out" | awk '$1 != 0' | head -1)
    [ -z "$bad" ] || { echo "FAIL stack-align: the array is ${bad%% *} bytes past a 64-byte boundary"; fail=1; }
    gbad=$(printf '%s\n' "$out" | awk '$3 != 0' | head -1)
    [ -z "$gbad" ] || { echo "FAIL stack-align: the global array is $(echo "$gbad" | awk '{print $3}') bytes past a 64-byte boundary"; fail=1; }
    sums=$(printf '%s\n' "$out" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
    [ "$sums" = 1 ] || { echo "FAIL stack-align: the sum varies"; fail=1; }
    msg="8 runs, the local and the global array 64-aligned"
else
    msg="not run (no x86-64 host)"
fi
[ $fail = 0 ] && echo "stack-align: ok ($msg)"
exit $fail
