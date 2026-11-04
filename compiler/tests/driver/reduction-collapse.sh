#!/bin/bash
# reduction-collapse.sh — an outer loop around an inner loop that adds the
# same total on every pass collapses to one pass and a multiply
# (loop-reduction-collapse), and nothing else does.
#
#   1. int_muldiv_hoist's shape: an earlier loop's counter carried unchanged
#      around the outer loop, and the inner sum written acc + (x + y), which
#      simplify reorders to x + (acc + y). A billion passes finish only if
#      the nest collapses; the total is checked against Python's.
#   2. A partial sum holding the accumulator is also read after the inner
#      loop: not collapsed, and -O3 prints what -O0 prints.
#   3. A term uses the outer index: not collapsed, -O3 prints what -O0 prints.
#
# Both compilers, at --par-style=cpu and the default.
#
#   bash tests/driver/reduction-collapse.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/reduction-collapse.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/hoist.xc" <<'EOF'
#import "Stdio.xc"
#define N 1024
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + (u32)argc;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)1000000000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + ((a[i] * (u32)7) / (u32)3) + (a[i] / (u32)11);
    Stdio.printf("%u\n", acc);
    return 0;
    }
EOF
cat > "$W/escape.xc" <<'EOF'
#import "Stdio.xc"
#define N 64
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = i * (u32)40503 + (u32)argc;
    u32 acc = (u32)0;
    u32 seen = (u32)0;
    for (u32 r = (u32)0; r < (u32)1000; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++)
            {
            u32 part = acc + a[i];
            acc = part + (a[i] >> (u32)3);
            seen = seen ^ part;
            }
        }
    Stdio.printf("%u %u\n", acc, seen);
    return 0;
    }
EOF
cat > "$W/outer.xc" <<'EOF'
#import "Stdio.xc"
#define N 64
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = i * (u32)40503 + (u32)argc;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)1000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (a[i] + r) / (u32)3;
    Stdio.printf("%u\n", acc);
    return 0;
    }
EOF

want=$(python3 -c "
s=0
for i in range(1024):
    v=(i*2654435761+1)&0xffffffff
    s+=((v*7)&0xffffffff)//3 + v//11
print((s*1000000000)&0xffffffff)")
run() { # timeout-guarded run: name binary
    perl -e 'alarm 20; exec @ARGV' "$1" 2>&1
}
for c in "$REF" "$XC"; do
    cn=$(basename "$c")
    for st in cpu auto; do
        if ! "$c" -q -O3 --par-style=$st -o "$W/h" "$W/hoist.xc" 2> "$W/err"; then
            echo "FAIL $cn $st hoist: does not build"; head -3 "$W/err"; fail=1; continue
        fi
        got=$(run "$W/h")
        [ "$got" = "$want" ] || { echo "FAIL $cn $st hoist: got '$got', want $want (a timeout means it did not collapse)"; fail=1; }
        for t in escape outer; do
            "$c" -q -O0 --par-style=cpu -o "$W/o0" "$W/$t.xc" && "$c" -q -O3 --par-style=$st -o "$W/o3" "$W/$t.xc" || { echo "FAIL $cn $st $t: does not build"; fail=1; continue; }
            a=$(run "$W/o0"); b=$(run "$W/o3")
            [ "$a" = "$b" ] || { echo "FAIL $cn $st $t: -O3 '$b' against -O0 '$a'"; fail=1; }
        done
    done
done
[ $fail = 0 ] && echo "reduction-collapse: ok"
exit $fail
