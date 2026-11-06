#!/bin/bash
# array-cast.sh — a cast of a decayed array to a pointer (`(u8*)got`) is a
# Bitcast in both compilers, never an IntToPtr, which treats the live pointer
# as an integer: so the two write the same assembly for it (arm64 Linux and
# x86-64 Linux; macOS on a Mac), with no self-move left in show() on arm64,
# and the program prints the array.
#
#   bash tests/driver/array-cast.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/arrcast.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/c.xc" <<'XEOF'
#import "Stdio.xc"
u32 show(u32 n)
    {
    u8 got[8];
    for (u32 i = (u32)0; i < n; i++)
        got[i] = (u8)((u32)104 + i);
    got[n] = (u8)0;
    Stdio.printf("%s\n", (u8*)got);
    return n;
    }
i32 main(i32 argc, u8** argv)
    {
    return (i32)show((u32)2) - 2;
    }
XEOF
TARGETS="arm64-linux x86_64-linux"; [ "$PLAT" = osx ] && TARGETS="arm64-linux x86_64-linux arm64"
for A in $TARGETS; do
    for C in "$REF" "$XC"; do
        "$C" -q -O2 -A "$A" -H . -S -o "$W/c.$A.$(basename "$C").s" "$W/c.xc" 2> "$W/err" || { echo "FAIL $(basename "$C") -A $A: build"; head -3 "$W/err"; fail=1; }
    done
    cmp -s "$W/c.$A.xcc.s" "$W/c.$A.xcc-xc.s" || { echo "FAIL -A $A: the two compilers write different assembly"; diff "$W/c.$A.xcc.s" "$W/c.$A.xcc-xc.s" | head -6; fail=1; }
    # In show() alone: the rest of the module (the par runtime, compiled in
    # where no prebuilt one is found) has self-moves of its own.
    case "$A" in arm64*)
        awk '{ l = $0; sub(/^_/, "", l) } l == "show:" { p = 1; next } p && /\.globl/ { exit } p' "$W/c.$A.xcc.s" > "$W/show.s"
        [ -s "$W/show.s" ] || { echo "FAIL -A $A: no show() in the assembly"; fail=1; }
        grep -qE '^[[:space:]]+mov (x[0-9]+), \1$' "$W/show.s" && { echo "FAIL -A $A: a self-move is left in show()"; fail=1; } ;;
    esac
done
case "$PLAT-$(uname -m)" in
    osx-arm64) NATIVE=arm64 ;; linux-x86_64) NATIVE=x86_64-linux ;; linux-aarch64|linux-arm64) NATIVE=arm64-linux ;; *) NATIVE= ;;
esac
if [ -n "$NATIVE" ]; then
    for C in "$REF" "$XC"; do
        "$C" -q -O2 -A "$NATIVE" -H . -o "$W/c.$(basename "$C")" "$W/c.xc" 2> "$W/err" || { echo "FAIL $(basename "$C"): build"; fail=1; continue; }
        got=$("$W/c.$(basename "$C")"); [ "$got" = "hi" ] || { echo "FAIL $(basename "$C"): printed '$got'"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "array-cast: ok"
exit $fail
