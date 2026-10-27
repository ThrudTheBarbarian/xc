#!/bin/bash
# ran-on.sh — which hardware ran a block (2026-10-27, owner: float results can
# differ between devices, so a program can ask which made them). On this
# machine's GPU, Par.ranOn names its runtime (metal: on a Mac, vulkan: on
# Linux); a loop --par-auto lifted is asked for by file:line, as XC_PAR_REPORT
# names it; and a C program asks with xc_par_ran_on("file.c:line").
#
#   bash tests/par/ran-on.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
GPU=$( [ "$PLAT" = osx ] && echo metal: || echo vulkan: )
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
# 1. A named block forced onto the GPU, then onto the CPU lanes.
cat > "$W/named.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
{
    u32 n = 1 << 20;
    float* a = new float[n];
    par fill
    {
        for (u32 i in 0..n)
            a[i] = (float)i * 0.5f;
    }
    Array* on = Par.ranOn("fill");
    for (u32 i = 0; i < on.count(); i = i + 1)
        Stdio.printf("%s\n", ((String*)on.get(i)).cString());
    return 0;
}
XC
"$XC" -q -O2 -H . -o "$W/named" "$W/named.xc" || { echo "FAIL ran-on: the named block does not build"; exit 1; }
got=$(XC_PAR=gpu XCC_SETTINGS_DIR="$W/s1" "$W/named" 2>/dev/null)
if [ -z "$got" ]; then
    echo "FAIL ran-on: XC_PAR=gpu names no device"; fail=1
elif [ "$(printf '%s\n' "$got" | head -1 | cut -c1-${#GPU})" != "$GPU" ] && [ "$got" != cpu ]; then
    echo "FAIL ran-on: XC_PAR=gpu gives '$got'"; fail=1
fi
got=$(XC_PAR=cpu XCC_SETTINGS_DIR="$W/s2" "$W/named" 2>/dev/null)
[ "$got" = cpu ] || { echo "FAIL ran-on: XC_PAR=cpu gives '$got'"; fail=1; }
# 2. A loop --par-auto lifted, named file:line.
cat > "$W/lifted.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
{
    u32 n = 1 << 20;
    float* a = new float[n];
    for (u32 i in 0..n)
        a[i] = (float)i * 0.25f;
    Stdio.printf("%u\n", Par.ranOn("lifted.xc:7").count());
    return 0;
}
XC
"$XC" -q -O2 -H . --par-auto -o "$W/lifted" "$W/lifted.xc" || { echo "FAIL ran-on: the lifted loop does not build"; exit 1; }
got=$(XC_PAR=cpu XCC_SETTINGS_DIR="$W/s3" "$W/lifted" 2>/dev/null)
[ "$got" = 1 ] || { echo "FAIL ran-on: lifted.xc:7 has '$got' devices"; XC_PAR_REPORT=1 XC_PAR=cpu XCC_SETTINGS_DIR="$W/s3" "$W/lifted" 2>&1 | grep 'par:' | head -3; fail=1; }
# 3. From C.
if command -v clang > /dev/null 2>&1; then
    cat > "$W/c.c" <<'C'
#include <stdio.h>
const char *xc_par_ran_on(const char *block);
int main(void)
{
    static float a[1 << 20];
    for (unsigned i = 0; i < (1u << 20); i++)
        a[i] = (float)i * 0.25f;
    printf("%s\n", xc_par_ran_on("c.c:6"));
    printf("[%s]\n", xc_par_ran_on("c.c:99"));
    return a[5] > 1.0f ? 0 : 1;
}
C
    "$XC" -q -O2 --par-auto -o "$W/c" "$W/c.c" || { echo "FAIL ran-on: the C program does not build"; fail=1; }
    if [ -x "$W/c" ]; then
        got=$(XC_PAR=cpu XCC_SETTINGS_DIR="$W/s4" "$W/c" 2>/dev/null | tr '\n' ' ')
        [ "$got" = "cpu [] " ] || { echo "FAIL ran-on: from C, '$got'"; XC_PAR_REPORT=1 XC_PAR=cpu XCC_SETTINGS_DIR="$W/s4" "$W/c" 2>&1 | grep 'par:' | head -3; fail=1; }
    fi
else
    echo "ran-on: no clang, the C part skipped"
fi
[ $fail = 0 ] && echo "ran-on: ok"
exit $fail
