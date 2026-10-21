#!/bin/bash
# canary.sh — stack canaries (2026-10-21): a function with a local array, an
# aggregate or a taken address keeps a random guard word between its locals and
# the frame above, set on entry and compared on every return. A write past a
# local array that reaches it stops the program (status 134) before the return
# uses whatever it overwrote. Unchecked builds included: this is the line a
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
"$XC" -q -O2 -H . -o "$W/s" "$W/s.xc" > "$W/s.b" 2>&1 || { echo "FAIL canary: does not build"; head -3 "$W/s.b"; exit 1; }
[ "$("$W/s" 2>&1)" = "fill 65" ] || { echo "FAIL canary: the in-range run gives '$("$W/s" 2>&1 | head -1)'"; fail=1; }
"$W/s" x > "$W/o" 2>&1; rc=$?
[ $rc = 134 ] && grep -q 'stack smashing detected' "$W/o" \
    || { echo "FAIL canary: a write 192 bytes past a local array was not stopped (exit $rc)"; head -2 "$W/o"; fail=1; }
grep -q '^fill' "$W/o" && { echo "FAIL canary: fill returned through a smashed frame"; fail=1; }
if [ "$PLAT" = osx ]; then
    for A in x86_64 win64; do
        "$XC" -q -O2 -A $A -H . -o "$W/s.$A" "$W/s.xc" > "$W/$A.out" 2>&1 \
            || { echo "FAIL canary: does not link for $A"; head -3 "$W/$A.out"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "--- canary: pass ---" || echo "--- canary: FAIL ---"
exit $fail
