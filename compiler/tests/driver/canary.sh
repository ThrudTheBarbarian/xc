#!/bin/bash
# canary.sh — stack canaries (2026-10-21): a function with a local array, an
# aggregate or a taken address keeps a random guard word between its locals and
# the frame above, set on entry and compared on every return. A write past a
# local array that reaches it stops the program (status 134) before the return
# uses whatever it overwrote; arrays lie next to the guard, so even a short
# overrun reaches it (#35). Unchecked builds included: this is the line a
# bounds check does not cover (a pointer walking off an array). On a Mac the
# x86-64 and win64 builds are linked too, though not run.
#
#   bash tests/driver/canary.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/s.xc" <<'XC'
#import "Stdio.xc"
u32 fill(u32 n)
    {
    u8 buf[8];
    u8* p = &buf[0];
    for (u32 i in 0..n)
        p[i] = (u8)$41;
    return (u32)buf[0];
    }
i32 main(i32 argc, u8** argv)
    {
    u32 n = argc > 1 ? (u32)200 : (u32)8;
    Stdio.printf("fill %u\n", fill(n));
    return 0;
    }
XC
"$XC" -q --par-style=cpu -O2 -H . -o "$W/s" "$W/s.xc" > "$W/s.b" 2>&1 || { echo "FAIL canary: does not build"; head -3 "$W/s.b"; exit 1; }
[ "$("$W/s" 2>&1)" = "fill 65" ] || { echo "FAIL canary: the in-range run gives '$("$W/s" 2>&1 | head -1)'"; fail=1; }
"$W/s" x > "$W/o" 2>&1; rc=$?
[ $rc = 134 ] && grep -q 'stack smashing detected' "$W/o" \
    || { echo "FAIL canary: a write 192 bytes past a local array was not stopped (exit $rc)"; head -2 "$W/o"; fail=1; }
grep -q '^fill' "$W/o" && { echo "FAIL canary: fill returned through a smashed frame"; fail=1; }
# Arrays lie next to the canary (#35): a write just 16 bytes past a local
# array reaches the guard, not another local (here a scalar whose address is
# taken, which the overrun would have changed unseen).
cat > "$W/n.xc" <<'XC'
#import "Stdio.xc"
u32 fill2(u32 n)
    {
    u32 keep = (u32)7;
    u32* kp = &keep;
    u8 buf[16];
    u8* p = &buf[0];
    for (u32 i in 0..n)
        p[i] = (u8)$42;
    return *kp + (u32)buf[0];
    }
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("fill2 %u\n", fill2(argc > 1 ? (u32)32 : (u32)16));
    return 0;
    }
XC
for A in host x86_64; do
    [ $A = x86_64 ] && [ "$PLAT" != linux ] && continue
    flags=; [ $A = x86_64 ] && flags="-A x86_64 -static"
    "$XC" -q --par-style=cpu -O2 $flags -H . -o "$W/n" "$W/n.xc" > "$W/n.b" 2>&1 || { echo "FAIL canary: the near overrun does not build ($A)"; head -3 "$W/n.b"; fail=1; continue; }
    [ "$("$W/n" 2>&1)" = "fill2 73" ] || { echo "FAIL canary: the near program's in-range run gives '$("$W/n" 2>&1 | head -1)' ($A)"; fail=1; }
    "$W/n" x > "$W/no" 2>&1; rc=$?
    [ $rc = 134 ] && grep -q 'stack smashing detected' "$W/no" \
        || { echo "FAIL canary: a write 16 bytes past a local array missed the canary ($A, exit $rc: $(head -1 "$W/no"))"; fail=1; }
done
# A C program's overrun is stopped too, whichever half compiled the function:
# xcc's canary, or clang's own stack protector for a function left to clang.
if clang --version >/dev/null 2>&1; then
    cat > "$W/c.c" <<'C'
#include <stdio.h>
#include <string.h>
int __attribute__((noinline)) fill(const char *s)
{
    char buf[8];
    strcpy(buf, s);
    return buf[0];
}
int main(int argc, char **argv)
{
    printf("%d\n", fill(argc > 1 ? "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" : "AB"));
    return 0;
}
C
    if "$XC" -q --par-style=cpu -O2 -H . -o "$W/c" "$W/c.c" > "$W/c.b" 2>&1; then
        [ "$("$W/c" 2>&1)" = "65" ] || { echo "FAIL canary: the C program's in-range run gives '$("$W/c" 2>&1 | head -1)'"; fail=1; }
        "$W/c" x > "$W/co" 2>&1; rc=$?
        [ $rc -ge 128 ] && ! grep -q '^65' "$W/co" \
            || { echo "FAIL canary: a C strcpy past a local array was not stopped (exit $rc)"; head -2 "$W/co"; fail=1; }
    else
        echo "FAIL canary: the C program does not build"; head -3 "$W/c.b"; fail=1
    fi
fi
if [ "$PLAT" = osx ]; then
    for A in x86_64 win64; do
        "$XC" -q --par-style=cpu -O2 -A $A -H . -o "$W/s.$A" "$W/s.xc" > "$W/$A.out" 2>&1 \
            || { echo "FAIL canary: does not link for $A"; head -3 "$W/$A.out"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "--- canary: pass ---" || echo "--- canary: FAIL ---"
exit $fail
