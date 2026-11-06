#!/bin/bash
# asm-separators.sh — a `;` ends a statement in an asm block on arm64 and
# x86-64, as on the 6502 (the rest of its line is a comment, and a line
# without one is a statement too), and
# a local named in brackets is its frame slot. Both compilers build both
# targets; the one this machine runs prints 42 42.
#
#   bash tests/driver/asm-separators.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/asmsep.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/a64.xc" <<'XEOF'
#import "Stdio.xc"
u32 addOne(u32 x)
    {
    u32 result = x;
    asm {
        ldr w9, [result];
        add w9, w9, #1;
        str w9, [result];
    }
    return result;
    }
u32 addTwo(u32 x)
    {
    u32 result = x;
    asm {
        ldr w9, [result];   // a comment after the statement
        add w9, w9, #2
        str w9, [result]; a remark the assembler never sees
    }
    return result;
    }
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("%lu %lu\n", addOne((u32)41), addTwo((u32)40));
    return 0;
    }
XEOF
cat > "$W/x64.xc" <<'XEOF'
#import "Stdio.xc"
u32 total;
u32 addOne(u32 x)
    {
    u32 result = x;
    asm {
        mov eax, dword ptr [result];
        add eax, 1;
        mov dword ptr [result], eax;
    }
    return result;
    }
u32 addTwo(u32 x)
    {
    total = x;
    asm {
        mov eax, dword ptr [rip + total];
        add eax, 2
        mov dword ptr [rip + total], eax; a remark the assembler never sees
    }
    return total;
    }
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("%lu %lu\n", addOne((u32)41), addTwo((u32)40));
    return 0;
    }
XEOF

NATIVE=
case "$PLAT-$(uname -m)" in
    osx-arm64)                 NATIVE=arm64 ;;
    linux-aarch64|linux-arm64) NATIVE=arm64-linux ;;
    linux-x86_64)              NATIVE=x86_64-linux ;;
esac
for C in "$REF" "$XC"; do
    n=$(basename "$C")
    for A in arm64-linux x86_64-linux; do
        src=$W/a64.xc; [ "$A" = x86_64-linux ] && src=$W/x64.xc
        "$C" -q -O2 -A "$A" -H . -o "$W/$A.$n" "$src" 2> "$W/err" || { echo "FAIL $n -A $A: build"; head -3 "$W/err"; fail=1; continue; }
        if [ "$A" = "$NATIVE" ]; then
            got=$("$W/$A.$n"); [ "$got" = "42 42" ] || { echo "FAIL $n -A $A: printed '$got'"; fail=1; }
        fi
    done
    if [ "$NATIVE" = arm64 ]; then
        "$C" -q -O2 -A arm64 -H . -o "$W/mac.$n" "$W/a64.xc" 2> "$W/err" || { echo "FAIL $n -A arm64: build"; head -3 "$W/err"; fail=1; continue; }
        got=$("$W/mac.$n"); [ "$got" = "42 42" ] || { echo "FAIL $n -A arm64: printed '$got'"; fail=1; }
    fi
done
[ $fail = 0 ] && echo "asm-separators: ok"
exit $fail
