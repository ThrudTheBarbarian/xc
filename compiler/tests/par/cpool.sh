#!/bin/bash
# cpool.sh — arrays inside one large block, written on the GPU (#325). A
# program with its own pool allocator (c-malloc/ownmain.c with ownheap.c) hands
# out pointers into one 48 MB global, which the runtime knows as one block. The
# lifted loop that fills two of them ran on the GPU with each array's buffer
# reaching to the end of the pool, and the second buffer's copy back put the
# bytes from before the run over what the kernel wrote into the first: the
# gather then read x as zeros (200000.0, clang 25175000.0). Each buffer now ends
# where the loop's footprint ends, and buffers that still share memory with one
# written keep the block on the CPU.
#
# Checked: ownmain.c with XC_PAR=gpu and under auto on its first run gives
# clang's answer; an xc program writing through two pointers into one global
# array and into one heap array gives the serial answer on the CPU and the GPU;
# on macOS the pool's fill loop and the xc loop over two separate arrays still
# run on the GPU.
#
#   bash tests/par/cpool.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
if [ "$PLAT" = osx ]; then export DYLD_LIBRARY_PATH=support/runtime-lib/arm64-macos; else export LD_LIBRARY_PATH=support/runtime-lib/$(uname -m | sed 's/aarch64/arm64/')-linux; fi
D=tests/par/c-malloc
fail=0
fresh() { rm -rf "$W/home"; mkdir -p "$W/home"; }
export HOME="$W/home"

# The C program with its own allocator.
if clang --version > /dev/null 2>&1; then
    clang -O2 -w -DOWN_HEAP_HERE -o "$W/own.ref" $D/ownmain.c || { echo "FAIL cpool: clang does not build ownmain.c"; exit 1; }
    want=$("$W/own.ref")
    if "$XC" -q -O2 -H . -DOWN_HEAP_HERE -o "$W/own" $D/ownmain.c > "$W/own.b" 2>&1; then
        for d in gpu auto; do
            fresh
            if [ $d = auto ]; then XC_PAR_REPORT=1 "$W/own" > "$W/own.$d" 2>&1
            else XC_PAR=$d XC_PAR_REPORT=1 "$W/own" > "$W/own.$d" 2>&1; fi
            got=$(grep -v '^par: ' "$W/own.$d" | tail -1)
            [ "$got" = "$want" ] && echo "  ok: own allocator, XC_PAR=$d: clang's answer ($got)" \
                || { echo "  FAIL: own allocator, XC_PAR=$d gives '$got', clang's '$want'"; fail=1; }
        done
        if [ "$PLAT" = osx ]; then
            grep -q 'ownmain.c:24: .*items on the GPU' "$W/own.gpu" && echo "  ok: the pool's fill loop runs on the GPU" \
                || { echo "  FAIL: the pool's fill loop did not run on the GPU"; sed 's/^/    /' "$W/own.gpu"; fail=1; }
        fi
    else
        echo "  FAIL: ownmain.c does not build"; head -5 "$W/own.b"; fail=1
    fi
else
    echo "  skipped: the C program (no clang)"
fi

# An xc program: two pointers into one global array and into one heap array,
# the later one in memory passed first, written on the GPU; and two separate
# arrays, which still run there.
cat > "$W/a.xc" <<'XC'
#import "Stdio.xc"
#define N 100003
u32 g[2 * N + 1];
void two(u32* p, u32* q, u32 n) { for (u32 i = (u32)0; i < n; i++) { p[i] = i * (u32)3 + (u32)1; q[i] = i * (u32)5 + (u32)2; } }
void apart(u32* p, u32* q, u32 n) { for (u32 i = (u32)0; i < n; i++) { p[i] = i * (u32)7 + (u32)3; q[i] = i * (u32)11 + (u32)4; } }
i32 main(i32 argc, u8** argv)
    {
    u32* a = new u32[2 * N + 1];
    u32* b = new u32[N];
    u32* c = new u32[N];
    two(&g[1 + N], &g[1], (u32)N);
    two(&a[1 + N], &a[1], (u32)N);
    apart(b, c, (u32)N);
    u64 s = (u64)0;
    u64 t = (u64)0;
    u64 u = (u64)0;
    for (u32 i = (u32)0; i < (u32)(2 * N + 1); i++) { s = s * (u64)31 + (u64)g[i]; t = t * (u64)31 + (u64)a[i]; }
    for (u32 i = (u32)0; i < (u32)N; i++) u = u * (u64)31 + (u64)b[i] + (u64)c[i];
    Stdio.printf("%lu %lu %lu\n", s, t, u);
    return 0;
    }
XC
"$XC" -q -O2 -H . -o "$W/a" "$W/a.xc" > "$W/a.b" 2>&1 || { echo "FAIL cpool: the xc program does not build"; head -5 "$W/a.b"; exit 1; }
"$XC" -q -O2 -H . --par-style=cpu -o "$W/a.ser" "$W/a.xc" > "$W/a.b" 2>&1 || { echo "FAIL cpool: the xc program's serial build"; exit 1; }
want=$("$W/a.ser")
for d in cpu gpu auto; do
    fresh
    if [ $d = auto ]; then XC_PAR_REPORT=1 "$W/a" > "$W/a.$d" 2>&1
    else XC_PAR=$d XC_PAR_REPORT=1 "$W/a" > "$W/a.$d" 2>&1; fi
    got=$(grep -v '^par: ' "$W/a.$d" | tail -1)
    [ "$got" = "$want" ] && echo "  ok: xc, XC_PAR=$d: the serial answer" \
        || { echo "  FAIL: xc, XC_PAR=$d gives '$got', serially '$want'"; fail=1; }
done
if [ "$PLAT" = osx ]; then
    grep -q 'a.xc:5: .*items on the GPU' "$W/a.gpu" && echo "  ok: the xc loop over two separate arrays runs on the GPU" \
        || { echo "  FAIL: the xc loop over two separate arrays did not run on the GPU"; sed 's/^/    /' "$W/a.gpu"; fail=1; }
fi
[ $fail = 0 ] && echo "--- cpool: pass ---" || echo "--- cpool: FAIL ---"
exit $fail
