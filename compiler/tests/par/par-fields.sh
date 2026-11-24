#!/bin/bash
# par-fields.sh — -Wpar-fields (#146, stage 1): for each array of structs a
# par block (or a lifted loop) uses, the fields it reads and writes, the bytes
# of each element those cover, and whether a GPU copy of those fields alone
# would move less than the copy of whole elements. A report only: the code is
# the same with it and without it, and nothing is said unless it is asked for.
# Needs a target with a GPU form (arm64 macOS, x86-64 Linux).
#
#   bash tests/par/par-fields.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) A=arm64 ;;
    Linux-x86_64) A=x86_64 ;;
    *) echo "--- par-fields: skipped (host) ---"; exit 0 ;;
esac
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
bad() { echo "  FAIL: $*"; fail=1; }
cat > "$W/f.xc" <<'EOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 65536
struct Inner { i16 a; i16 b; }
struct Body { float x; float y; float z; float vx; float vy; float vz; float m; Inner tag; i32 id; }
Body bs[N];
i32 main(void)
{
    for (u32 i in 0..N)
    {
        bs[i].x = (float)i; bs[i].y = 0.0f; bs[i].z = 0.0f;
        bs[i].vx = 0.5f; bs[i].vy = 0.0f; bs[i].vz = 0.0f;
        bs[i].m = 1.0f; bs[i].tag.a = (i16)1; bs[i].tag.b = (i16)2; bs[i].id = (i32)i;
    }
    par move
    {
        for (u32 i in 0..N)
        {
            bs[i].x = bs[i].x + bs[i].vx * 0.01f;
            bs[i].tag.b = (i16)3;
        }
    }
    float s = 0.0f;
    for (u32 i in 0..N)
        s = s + bs[i].x;
    Stdio.printf("%d\n", (i32)s);
    return 0;
}
EOF
"$XC" -q -A $A -H . -O2 -Wpar-fields -S "$W/f.xc" -o "$W/on.s" > "$W/on.err" 2>&1 \
    || { echo "FAIL par-fields: f.xc does not build"; head -5 "$W/on.err"; exit 1; }
sed 's/\x1b\[[0-9;]*m//g' "$W/on.err" > "$W/on.txt"
want="this 'par' block reads x, vx and writes x, tag.b of its array of Body (36 bytes an element): 10 of 36 bytes an element; a copy of those fields alone would move 8 bytes an element to the GPU and 6 back, where whole elements move 36 and 36"
grep -qF "$want" "$W/on.txt" || { bad "the par block's report"; grep warning "$W/on.txt" | head -3; }
grep -qF "it uses most of each element, so the in-place copy stays" "$W/on.txt" \
    || bad "the initialising loop (every field written) is not reported as staying in place"
# Off by default, and the same code either way.
"$XC" -q -A $A -H . -O2 -S "$W/f.xc" -o "$W/off.s" > "$W/off.err" 2>&1
grep -q "its array of" "$W/off.err" && bad "a report without -Wpar-fields"
cmp -s "$W/on.s" "$W/off.s" || bad "-Wpar-fields changes the code"
# A C program's lifted loop: its structs have no names there, so the fields
# are offsets and types.
if clang --version > /dev/null 2>&1; then
    cat > "$W/p.c" <<'C'
#include <stdio.h>
#define N 1000000
struct P { float x, y, z, vx, vy, vz, m; int id; };
struct P p[N];
int main(void)
{
    for (int i = 0; i < N; i++) { p[i].x = i; p[i].vx = 0.5f; p[i].y = p[i].z = p[i].vy = p[i].vz = 0; p[i].m = 1; p[i].id = i; }
    for (int i = 0; i < N; i++)
        p[i].x = p[i].x + p[i].vx * 0.01f;
    float s = 0;
    for (int i = 0; i < N; i++) s = s > p[i].x ? s : p[i].x;
    printf("%.1f\n", s);
    return 0;
}
C
    "$XC" -q -O2 -H . -Wpar-fields -o "$W/p" "$W/p.c" > "$W/c.err" 2>&1 || { bad "p.c does not build"; head -5 "$W/c.err"; }
    grep -qF "p.c:8:" "$W/c.err" && grep -qF "this loop (--par-style) reads +0 F32, +12 F32 and writes +0 F32 of its array of 32-byte structs: 8 of 32 bytes an element" "$W/c.err" \
        || { bad "the C loop's report"; grep warning "$W/c.err" | head -3; }
fi
[ $fail = 0 ] && echo "--- par-fields: pass ---" || { echo "--- par-fields: FAIL ---"; exit 1; }
