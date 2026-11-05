#!/bin/bash
# arm64-chain-rotate.sh — an insertion sort's `while (j > 0 && a[j-1] > v)`
# loop on arm64 (issue #20):
#
#   1. arm64 Linux (the row's rotateChain): the loop is rotated, its test at
#      the bottom, and the exit edge's copies go to an out-of-line stub, so
#      the body falls into its rotated test and the back edge is the only
#      branch it takes;
#   2. arm64 macOS: not rotated (Apple's cores run the unrotated loop as fast);
#   3. both compilers write the same assembly for each, and the program built
#      for this Mac prints at -O3 what it prints at -O0.
#
#   bash tests/driver/arm64-chain-rotate.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/arm64-chain-rotate.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/s.xc" <<'EOF'
#import "Stdio.xc"
#define N 64
i32 main(i32 argc, u8** argv)
    {
    u32 a[N]; u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)2000; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++)
            a[i] = ((i * (u32)2654435761) ^ (r * (u32)40503)) + (u32)argc;
        for (u32 i = (u32)1; i < (u32)N; i++)
            {
            u32 v = a[i]; u32 j = i;
            while (j > (u32)0 && a[j - (u32)1] > v) { a[j] = a[j - (u32)1]; j = j - (u32)1; }
            a[j] = v;
            }
        acc = acc + a[0] + a[N - 1];
        }
    Stdio.printf("%u\n", acc);
    return 0;
    }
EOF

main_of() { awk '/^_main:/{p=1} p&&/^_[A-Za-z]/&&!/^_main:/{exit} p' "$1"; }

for A in arm64-linux arm64; do
    for C in "$REF" "$XC"; do
        n=$(basename "$C")
        if ! "$C" -q -O3 -A "$A" -S -o "$W/s.$A.$n.s" "$W/s.xc" 2> "$W/err"; then
            echo "FAIL $n -A $A: build"; head -5 "$W/err"; fail=1
        fi
    done
    if ! cmp -s "$W/s.$A.xcc.s" "$W/s.$A.xcc-xc.s"; then
        echo "FAIL -A $A: the two compilers write different assembly"; fail=1
    fi
    main_of "$W/s.$A.xcc-xc.s" > "$W/main.$A"
    rot=$(grep -c '_rot:' "$W/main.$A")
    cold=$(grep -c '_cold_[0-9]*:' "$W/main.$A")
    if [ "$A" = arm64-linux ]; then
        [ "$rot" -ge 1 ] || { echo "FAIL -A $A: the chain loop is not rotated"; fail=1; }
        [ "$cold" -ge 1 ] || { echo "FAIL -A $A: no out-of-line exit stub"; fail=1; }
    else
        [ "$rot" = 0 ] || { echo "FAIL -A $A: rotated on an Apple core"; fail=1; }
    fi
done

if [ "$PLAT" = osx ]; then
    for C in "$REF" "$XC"; do
        n=$(basename "$C")
        "$C" -q -O0 -o "$W/o0.$n" "$W/s.xc" && "$C" -q -O3 -o "$W/o3.$n" "$W/s.xc" || { echo "FAIL $n: build"; fail=1; continue; }
        a=$("$W/o0.$n"); b=$("$W/o3.$n")
        [ "$a" = "$b" ] || { echo "FAIL $n: -O3 prints $b, -O0 $a"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "arm64-chain-rotate: ok"
exit $fail
