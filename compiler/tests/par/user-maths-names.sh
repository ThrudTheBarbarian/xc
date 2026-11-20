#!/bin/bash
# user-maths-names.sh — a function of the program named like a GPU maths
# built-in stays the program's (#336). The GPU printers took any callee whose
# bare name was min, max, sqrt, ... for the built-in: a user's
# `float max(float a, float b)` that adds its arguments printed 10.0 on the
# GPU (Metal's max(10, 1)) where the CPU printed 11.0. Now only Math's methods,
# the _xm_ helpers and the C maths library names are built-ins. Checked: the
# block gives the CPU's answer on the CPU and on this host's GPU, in both
# compilers; a host without a GPU runs it on the CPU and checks the same.
#
#   bash tests/par/user-maths-names.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=bin/$PLAT/xcc
[ -x "$XC" ] || { echo "FAIL user-maths-names: no compiler at $XC"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
if [ "$PLAT" = osx ]; then export DYLD_LIBRARY_PATH=support/runtime-lib/arm64-macos; else export LD_LIBRARY_PATH=support/runtime-lib/$(uname -m | sed 's/aarch64/arm64/')-linux; fi
fail=0
cat > "$W/m.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
float gA[1024];
float max(float a, float b)
{
    float s = a;
    for (u32 k = 0; k < 3; k = k + 1)
        s = s + b * (float)(k + 1) - b * (float)k;
    return s - 2.0f * b;
}
i32 main(void)
{
    par mx
    {
        for (u32 i in 0..1024)
            gA[i] = max((float)i, 1.0f);
    }
    Stdio.printf("%.1f\n", (double)gA[10]);
    return 0;
}
XC
for c in "$XC" "$REF"; do
    [ -x "$c" ] || continue
    "$c" -q -O2 -H . -o "$W/m" "$W/m.xc" > "$W/b" 2>&1 || { echo "FAIL user-maths-names: $c does not build"; tail -3 "$W/b"; fail=1; continue; }
    for d in cpu gpu; do
        XC_PAR=$d XC_PAR_REPORT=1 "$W/m" > "$W/r" 2>&1
        got=$(tail -1 "$W/r")
        [ "$got" = "11.0" ] || { echo "FAIL user-maths-names: $c, XC_PAR=$d printed '$got', want 11.0 ($(grep -m1 'items on' "$W/r"))"; fail=1; }
    done
    echo "user-maths-names: $c: the GPU leg ran $(grep -m1 -oE 'on the (GPU|CPU)' "$W/r")"
done
[ $fail = 0 ] && echo "user-maths-names: ok"
exit $fail
