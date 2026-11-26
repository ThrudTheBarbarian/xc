#!/bin/bash
# par-debug-info.sh — -g changes the debug information only: a par block is
# checked and built as it is without it (#708).
#
#   * A block whose items read each other's results (a scan) is refused with
#     -g as without it. -g used to keep every local of the block in a frame
#     slot for the debugger; the independence check found no loop counter in
#     that form and let the block through, and it ran wrong (782, not 100000).
#   * A block whose items are independent builds with -g without the warning
#     that it runs on the CPU only, and gives the same answer.
#
# Both drivers, -O0 and -O2, on this machine.
#
#   bash tests/driver/par-debug-info.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0; pass=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ok()  { pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=1; }

cat > "$W/scan.xc" <<'XCEOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
i32 main(void)
{
    simd: u32* a = new u32[N];
    a[0] = (u32)1;
    par
    {
        for (u32 i in 1..N)
            a[i] = a[i - 1] + (u32)1;
    }
    Stdio.printf("%u\n", a[N - 1]);
    return 0;
}
XCEOF
cat > "$W/indep.xc" <<'XCEOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
i32 main(void)
{
    simd: u32* a = new u32[N];
    par
    {
        for (u32 i in 0..N)
            a[i] = i * (u32)3 + (u32)1;
    }
    u64 s = 0;
    for (u32 i in 0..N)
        s = s + (u64)a[i];
    Stdio.printf("%lu %u\n", s, a[N - 1]);
    return 0;
}
XCEOF

for c in "$REF" "$XC"; do
    [ -x "$c" ] || { bad "no compiler at $c"; continue; }
    n=$(basename "$c")
    for O in 0 2; do
        if "$c" -q -g -O$O -o "$W/scan" "$W/scan.xc" > "$W/err" 2>&1; then
            bad "$n -g -O$O built the scan (it prints $("$W/scan"))"
        elif grep -q "must be independent" "$W/err"; then ok
        else bad "$n -g -O$O refused the scan for another reason: $(head -1 "$W/err")"; fi

        "$c" -q -g -O$O -o "$W/indep" "$W/indep.xc" > "$W/err" 2>&1 || { bad "$n -g -O$O indep build: $(head -1 "$W/err")"; continue; }
        if grep -q "runs on the CPU only" "$W/err"; then bad "$n -g -O$O: the independent block runs on the CPU only"; else ok; fi
        out=$("$W/indep")
        [ "$out" = "14999950000 299998" ] && ok || bad "$n -g -O$O indep printed '$out'"
    done
done

echo "par-debug-info: $pass passed$([ $fail = 0 ] || echo ', FAILURES')"
exit $fail
