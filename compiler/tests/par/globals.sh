#!/bin/bash
# globals.sh — global arrays a GPU may share (gpu-globals): a numeric global
# array of 64 KB or more gets pages of its own (on a page, padded to whole
# 16 KB pages) and is registered with the runtime's block registry, so a
# unified-memory GPU uses it in place instead of copying it in and out, and a
# discrete card keeps an unwritten copy resident. An xc program's arrays are
# laid out by xcc's back end; a C program's are clang's, padded in the IR
# clang compiles (the C path). Each program prints whether its arrays sit on a
# page, which holds on every host; on macOS (Metal shares any registered
# block) the par report must say the arrays were shared in place.
#
#   bash tests/par/globals.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/g.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 4194304
float xs[N];
float ys[N];
u32 small[16];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i in 0..N) { xs[i] = (float)(i % (u32)1000) * 0.5f; ys[i] = 1.0f; }
    for (u32 r in 0..3)
        {
        par saxpy
            {
            for (u32 i in 0..N)
                ys[i] = 2.0f * xs[i] + ys[i];
            }
        }
    u64 a = (u64)(pointer)&xs[0] | (u64)(pointer)&ys[0];
    // The last elements of both arrays: what a write just before one of
    // them (into the other's end) would change.
    Stdio.printf("%.1f %.1f %.1f %.1f ", (double)(xs[N - 5]), (double)(xs[N - 4]), (double)(ys[N - 5]), (double)(ys[N - 4]));
    Stdio.printf("%.1f %u %s\n", (double)(ys[N - 1]), small[3], (a & (u64)4095) == (u64)0 ? "paged" : "not paged");
    return 0;
    }
XC
"$XC" -q -O2 -H . -o "$W/g" "$W/g.xc" > "$W/g.b" 2>&1 || { echo "FAIL globals: the xc program does not build"; head -3 "$W/g.b"; fail=1; }
if [ -x "$W/g" ]; then
    for d in cpu gpu; do
        got=$(XC_PAR=$d "$W/g" 2>/dev/null)
        [ "$got" = "149.5 150.0 898.0 901.0 910.0 0 paged" ] || { echo "FAIL globals: xc ($d) gives '$got', wanted '149.5 150.0 898.0 901.0 910.0 0 paged'"; fail=1; }
    done
    if [ "$(uname -s)" = Darwin ]; then
        XC_PAR=gpu XC_PAR_REPORT=1 "$W/g" 2>&1 | grep -q 'bytes shared in place' \
            || { echo "FAIL globals: Metal copied the xc program's global arrays"; fail=1; }
    fi
fi
# On a CUDA card (the Windows GPU host, when build.env names one): pinning a
# global array for a copy once took it for a heap block, read its length from
# the 40 bytes before it and wrote the unpin hook there, into the end of the
# previous global (xs, which ys[N-1] is computed from). One card and the tiled
# path over both gave wrong sums.
WH=${XTC_WIN_GPU_HOST:-$(sed -n 's/^XTC_WIN_GPU_HOST=//p' build.env 2>/dev/null)}
if [ -n "$WH" ] && "$XC" -q -O2 -A win64 -H . -o "$W/gw.exe" "$W/g.xc" > "$W/gw.b" 2>&1; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    D="xcc-globals.$$"
    if ssh $SSHO "$WH" "New-Item -ItemType Directory $D | Out-Null" && scp -q $SSHO "$W/gw.exe" "$WH:$D/"; then
        for d in cpu gpu gpus; do
            got=$(ssh $SSHO "$WH" "cd $D; \$env:XC_PAR='$d'; .\\gw.exe" 2>/dev/null | tr -d '\r')
            [ "$got" = "149.5 150.0 898.0 901.0 910.0 0 paged" ] || { echo "FAIL globals: win64 ($d) gives '$got', wanted '149.5 150.0 898.0 901.0 910.0 0 paged'"; fail=1; }
        done
        ssh $SSHO "$WH" "Remove-Item -Recurse -Force $D -ErrorAction SilentlyContinue" || true
    fi
fi
if clang --version >/dev/null 2>&1; then
    cat > "$W/c.c" <<'C'
#include <stdio.h>
#define N 4194304
float xs[N], ys[N];
void step(void)
{
    for (int i = 0; i < N; i++)
        ys[i] = 2.0f * xs[i] + ys[i];
}
int main(void)
{
    for (int i = 0; i < N; i++) {
        xs[i] = (float)(i % 1000) * 0.5f;
        ys[i] = 1.0f;
    }
    for (int r = 0; r < 3; r++)
        step();
    unsigned long a = (unsigned long)xs | (unsigned long)ys;
    printf("%.1f %s\n", ys[N - 1], (a & 4095) == 0 ? "paged" : "not paged");
    return 0;
}
C
    "$XC" -q -O3 --par-auto -H . -o "$W/c" "$W/c.c" > "$W/c.b" 2>&1 || { echo "FAIL globals: the C program does not build"; head -3 "$W/c.b"; fail=1; }
    if [ -x "$W/c" ]; then
        for d in cpu gpu; do
            got=$(XC_PAR=$d "$W/c" 2>/dev/null)
            [ "$got" = "910.0 paged" ] || { echo "FAIL globals: C ($d) gives '$got', wanted '910.0 paged'"; fail=1; }
        done
        if [ "$(uname -s)" = Darwin ]; then
            XC_PAR=gpu XC_PAR_REPORT=1 "$W/c" 2>&1 | grep -q 'bytes shared in place' \
                || { echo "FAIL globals: Metal copied the C program's global arrays"; fail=1; }
        fi
    fi
fi
[ $fail = 0 ] && echo "--- globals: pass ---" || echo "--- globals: FAIL ---"
exit $fail
