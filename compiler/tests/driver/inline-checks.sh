#!/bin/bash
# inline-checks.sh — -fbounds-check=light inlines the subscript checks in loops
# (2026-10-29)
#
# A loop over a heap array whose bound bounds-elide cannot prove: under
# -fbounds-check=light at -O2 its check is inline (main calls no
# _xt_check_bounds), under -fbounds-check (the debug build) it stays a call.
# Either way the read past the end still stops the program with the report.
# arm64 here, and the x86-64 code when the host can assemble it.
#
#   bash tests/driver/inline-checks.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/t.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
{
    u64 s = 0;
    u32 n = (u32)(100 + argc);
    i32* p = new i32[100];
    for (u32 i = 0; i < 100; i = i + 1) p[i] = (i32)i;
    for (u32 i = 0; i < n; i = i + 1) s = s + (u64)p[i];
    Stdio.printf("%lu\n", s);
    return 0;
}
XC
# calls in main: label, assembly file
calls() {
    awk '/^_?main:/{f=1;next} f&&/^[[:space:]]*\.(globl|type|size)[[:space:]]/{exit} f' "$2" \
        | grep -cE '(bl|call)[[:space:]]+_?_xt_check_bounds'
}
ARCHS="arm64"
[ "$(uname -m)" = x86_64 ] && ARCHS="x86_64"
"$XC" -q -A x86_64 -static -O2 -fbounds-check=light -S -o "$W/probe.s" "$W/t.xc" 2>/dev/null && ARCHS="$ARCHS x86_64"
for a in $(echo $ARCHS | tr ' ' '\n' | sort -u); do
    ext=""; [ "$a" = x86_64 ] && ext="-static"
    "$XC" -q -A "$a" $ext -O2 -fbounds-check=light -S -o "$W/l.s" "$W/t.xc" || { echo "FAIL ($a): light does not build"; fail=1; continue; }
    "$XC" -q -A "$a" $ext -O2 -fbounds-check -S -o "$W/d.s" "$W/t.xc" || { echo "FAIL ($a): debug does not build"; fail=1; continue; }
    l=$(calls light "$W/l.s"); d=$(calls debug "$W/d.s")
    [ "$l" = 0 ] || { echo "FAIL inline-checks ($a): -fbounds-check=light's loop still calls the check ($l)"; fail=1; }
    [ "$d" -ge 1 ] || { echo "FAIL inline-checks ($a): -fbounds-check's loop no longer calls the check"; fail=1; }
done
# The inlined check still stops the read past the end, with the site.
if [ "$(uname -m)" = arm64 ] || [ "$(uname -m)" = x86_64 ]; then
    "$XC" -q -O2 -fbounds-check=light -o "$W/t" "$W/t.xc" || { echo "FAIL: light does not link"; exit 1; }
    out=$("$W/t" 2>&1); rc=$?
    { [ $rc != 0 ] && printf '%s\n' "$out" | grep -q 'index 100, but the array holds 100 elements'; } \
        || { echo "FAIL inline-checks: the inlined check does not stop the read past the end (rc=$rc)"; printf '%s\n' "$out"; fail=1; }
fi
[ $fail = 0 ] && echo "inline-checks: ok ($ARCHS)"
exit $fail
