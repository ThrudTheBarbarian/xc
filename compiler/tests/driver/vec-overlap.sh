#!/bin/bash
# vec-overlap.sh — a loop over two pointers that overlap (#95). The vector loop
# reads a whole vector before it writes, so with the destination one element
# past the source it read values the loop as written had already overwritten:
# `a[i] = b[i] * 3` with a = b + 1 printed 3 27 189 where the loop gives 0 0 0.
# Built as a plain loop and as a par block (whose overlap check runs the same
# body serially), on arm64 here and on x86-64 where a Linux host can run it;
# the loops over objects the IR knows apart (a global, a local, a new array)
# must still vectorise unchecked, and the pointer loop vectorised behind its
# check (the preheader sends overlapping bases to the scalar loop).
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=${REF:-bin/$PLAT/xcc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/a.xc" <<'XC'
#import "Stdio.xc"
void f(u32* a, u32* b) { for (u32 i = (u32)0; i < (u32)64; i++) a[i] = b[i] * (u32)3; }
void g(u32* a, u32* b, u32 n) { for (u32 i = (u32)0; i < n; i++) a[i] = b[i] * (u32)3; }
i32 main(i32 argc, u8** argv)
    {
    u32* x = new u32[200000];
    for (u32 i = (u32)0; i < (u32)200000; i++) x[i] = i;
    f(&x[1], &x[0]);
    Stdio.printf("%u %u %u\n", x[2], x[5], x[64]);
    for (u32 i = (u32)0; i < (u32)200000; i++) x[i] = i;
    g(&x[1], &x[0], (u32)100000);
    Stdio.printf("%u %u %u\n", x[2], x[5], x[64]);
    return 0;
    }
XC
printf '0 0 0\n0 0 0\n' > "$W/want"
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
u32 g[64];
i32 main(i32 argc, u8** argv)
    {
    u32 loc[64]; u32* h = new u32[64]; u32* h2 = new u32[64];
    for (u32 i = (u32)0; i < (u32)64; i++) { loc[i] = (u32)argc; h2[i] = i; }
    for (u32 i = (u32)0; i < (u32)64; i++) h[i] = loc[i] * (u32)3;
    for (u32 i = (u32)0; i < (u32)64; i++) g[i] = h2[i] * (u32)3;
    Stdio.printf("%u %u\n", h[3], g[5]);
    return 0;
    }
XC
RT=support/runtime-lib/arm64-macos
for c in "$XC" "$REF"; do
    n=$(basename "$c")
    for st in cpu auto; do
        if [ "$PLAT" = osx ]; then
            "$c" -q -H . -O3 --par-style=$st -o "$W/a-$st" "$W/a.xc" > "$W/e" 2>&1 || { echo "FAIL vec-overlap: $n $st: does not build"; fail=1; continue; }
            DYLD_LIBRARY_PATH=$RT XC_PAR_REMOTE=none "$W/a-$st" > "$W/got" 2>/dev/null
            cmp -s "$W/got" "$W/want" || { echo "FAIL vec-overlap: $n arm64 $st: $(tr '\n' ' ' < "$W/got")"; fail=1; }
        fi
    done
    # The pointer loop keeps its vector code, behind the preheader's check.
    "$c" -q -H . -O3 -A arm64 --par-style=cpu -S -o "$W/a.s" "$W/a.xc" > "$W/e" 2>&1 || { echo "FAIL vec-overlap: $n: a does not build"; fail=1; continue; }
    v=$(awk '/^_f:/{p=1;next} p&&/^_[A-Za-z]/{p=0} p' "$W/a.s" | grep -cE '\.4s')
    [ "$v" -ge 1 ] || { echo "FAIL vec-overlap: $n: the loop over two pointers is no longer vectorised"; fail=1; }
    # Distinct objects still vectorise: the copies of main's two loops.
    "$c" -q -H . -O3 -A arm64 --par-style=cpu -S -o "$W/b.s" "$W/b.xc" > "$W/e" 2>&1 || { echo "FAIL vec-overlap: $n: b does not build"; fail=1; continue; }
    v=$(awk '/^_main:/{p=1;next} p&&/^_[A-Za-z]/{p=0} p' "$W/b.s" | grep -cE '\.4s')
    [ "$v" -ge 4 ] || { echo "FAIL vec-overlap: $n: loops over distinct objects no longer vectorise ($v vector lines)"; fail=1; }
    # x86-64: built here, run where the host is Linux.
    if [ "$PLAT" = linux ]; then
        "$c" -q -H . -O3 -A x86_64 -static --par-style=cpu -o "$W/ax" "$W/a.xc" > "$W/e" 2>&1 || { echo "FAIL vec-overlap: $n x86_64: does not build"; fail=1; continue; }
        "$W/ax" > "$W/got" 2>/dev/null
        cmp -s "$W/got" "$W/want" || { echo "FAIL vec-overlap: $n x86_64: $(tr '\n' ' ' < "$W/got")"; fail=1; }
    fi
done
[ $fail -eq 0 ] && echo "--- vec-overlap: overlapping pointers keep the loop's answer; pointer and distinct-object loops vectorise ---"
exit $fail
