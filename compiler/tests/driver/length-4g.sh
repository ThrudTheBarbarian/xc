#!/bin/bash
# length-4g.sh — a heap array of more than 2^32 elements on a 64-bit target
# (#321): `.length` is its whole count, not the count mod 2^32, and
# `for (v in a)` visits every element; assigned to a u32 it stops the program
# with the site instead of wrapping. Both compilers, -O0 and -O2. It needs
# about 4.3 GB per run, so it runs only where the host has 12 GB free, and
# one program at a time; elsewhere it says so and passes.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
free_gb() {
    if [ -r /proc/meminfo ]; then awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo
    else echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 / 2 )); fi
}
[ "$(free_gb)" -ge 12 ] || { echo "length-4g: under 12 GB free, skipped"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/big.xc" <<'EOF'
#import "Stdio.xc"
u64 size(void) { return (u64)4294967299; }    // 2^32 + 3
i32 main(void)
{
    u64 n = size();
    u8* a = new u8[n];
    a[(u64)5] = (u8)1;
    a[(u64)4294967296] = (u8)2;               // past 2^32
    a[n - (u64)1] = (u8)4;
    u64 sum = (u64)0;
    u64 seen = (u64)0;
    for (u8 v in a)
        {
        sum = sum + (u64)v;
        seen = seen + (u64)1;
        }
    Stdio.printf("length %llu, visited %llu, sum %llu\n", a.length, seen, sum);
    delete a;
    return 0;
}
EOF
want="length 4294967299, visited 4294967299, sum 7"
cat > "$W/trap.xc" <<'EOF'
#import "Stdio.xc"
u64 size(void) { return (u64)4294967299; }
i32 main(void)
{
    u8* a = new u8[size()];
    u32 n = a.length;
    Stdio.printf("wrapped to %u\n", n);
    return 0;
}
EOF
twant="xcc: trap.xc:6:14: an array's length does not fit a u32; use u64"
fail=0
for c in bin/$XC_PLAT/xcc bin/$XC_PLAT/xcc-xc; do
    [ -x "$c" ] || continue
    for o in -O0 -O2; do
        "$c" -q $o -H . -o "$W/big" "$W/big.xc" > "$W/e" 2>&1 || { echo "FAIL $(basename "$c") $o: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        got=$("$W/big" 2>&1)
        if [ "$got" = "$want" ]; then echo "PASS $(basename "$c") $o: $got"
        else echo "FAIL $(basename "$c") $o: got '$got', want '$want'"; fail=1; fi
        "$c" -q $o -H . -o "$W/trap" "$W/trap.xc" > "$W/e" 2>&1 || { echo "FAIL $(basename "$c") $o trap: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        got=$("$W/trap" 2>&1); rc=$?
        if [ $rc = 134 ] && [ "$got" = "$twant" ]; then echo "PASS $(basename "$c") $o: u32 destination stops: $got"
        else echo "FAIL $(basename "$c") $o trap: status $rc, got '$got', want '$twant'"; fail=1; fi
    done
done
exit $fail
