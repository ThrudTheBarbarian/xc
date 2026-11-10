#!/bin/bash
# outlined-gpu.sh — blocks the IR outliner made (ParFnChunk) on the GPU. The
# runtime asks a block's gpuLength(k) by capture (the kernel header's
# `buf=off:k:es`), and the outliner's gpuLength answered by record field
# (3 + k): every pointer capture reported no size and the block stayed on the
# CPU, and with five or more captures the fourth was given the first's length.
# A length of 0 counted as a size: a device buffer of no bytes (nil on Metal)
# took the kernel's writes, and the program read zeros. Now a block over
# runtime arrays with five captures runs on the GPU and gives the CPU's
# output, shared in place and copied (pointers off the block's 256-byte
# grain), and a C loop over malloc'd arrays gives clang's output under
# XC_PAR=gpu, on the GPU or the CPU. A block whose header says every
# iteration touches a capture across its footprint (whole=<k>) has that
# footprint as the capture's length where the runtime knows no block for it.
# On Linux each of CUDA and Vulkan is run on its own; the GPU is required
# where the run names a device.
#
#   bash tests/par/outlined-gpu.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
runs="cpu gpu"
[ "$PLAT" = linux ] && runs="cpu gpu cuda vulkan"
envFor() {
    case $1 in
        cuda|vulkan) echo "XC_PAR=gpu XC_PAR_GPU=$1" ;;
        *) echo "XC_PAR=$1" ;;
    esac
}
# Five pointer captures (field 3 + k for k = 0..4), over arrays the runtime
# allocated (64 KB and more, so it knows their blocks).
cat > "$W/five.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
void mix(float* a, float* b, float* c, float* d, float* e, i64 n)
    {
    for (i64 i = 0; i < n; i++)
        {
        d[i] = a[i] * b[i] - c[i];
        e[i] = a[i] + 2.0 * b[i] + c[i];
        }
    }
i32 main(void)
    {
    i64 n = 1 << 20;
    float* a = new float[n + 64];
    float* b = new float[n + 64];
    float* c = new float[n + 64];
    float* d = new float[n + 64];
    float* e = new float[n + 64];
    for (i64 i = 0; i < n + 64; i++)
        {
        a[i] = (float)(i % 97);
        b[i] = (float)(i % 13) * 0.5;
        c[i] = (float)(i % 7);
        d[i] = -1.0;
        e[i] = -1.0;
        }
    i64 off = (i64)OFF;
    mix(a + off, b + off, c + off, d + off, e + off, n);
    double s = 0.0;
    for (i64 i = 0; i < n + 64; i++)
        s = s + (double)d[i] + (double)e[i];
    Stdio.printf("%.1f %.1f %.1f %.1f\n", (double)d[off + 12345], (double)e[off + 777], (double)d[0], s);
    return 0;
    }
XC
for off in 0 1; do
    sed "s/(i64)OFF/(i64)$off/" "$W/five.xc" > "$W/five$off.xc"
    XC_PAR_PROPOSE=outline XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -H . -o "$W/five$off" "$W/five$off.xc" > "$W/five$off.b" 2>&1 \
        || { echo "FAIL outlined-gpu: five captures (offset $off) does not build"; head -3 "$W/five$off.b"; fail=1; continue; }
    want=$(XC_PAR=cpu "$W/five$off" 2>/dev/null)
    for r in $runs; do
        mkdir -p "$W/st.$off.$r"
        env $(envFor "$r") XCC_SETTINGS_DIR="$W/st.$off.$r" XC_PAR_REPORT=1 "$W/five$off" > "$W/o" 2> "$W/e"
        got=$(grep -v '^par:' "$W/o")
        [ "$got" = "$want" ] || { echo "FAIL outlined-gpu: five captures (offset $off, $r) gives '$got', the CPU '$want'"; fail=1; }
        [ "$r" = cpu ] && continue
        # Metal always; on Linux where the run found a device of that kind.
        if [ "$PLAT" = osx ] || grep -qE 'par: (Vulkan|CUDA) device' "$W/o" "$W/e"; then
            grep -qE "five$off.xc:5: [0-9]+ items on the GPU" "$W/o" "$W/e" \
                || { echo "FAIL outlined-gpu: five captures (offset $off, $r) did not run on the GPU:"; grep -h 'par:' "$W/o" "$W/e" | head -4; fail=1; }
        fi
    done
done
# whole=<k>: a block the runtime knows no block of memory for (malloc), whose
# header says every iteration touches capture k across its footprint, takes
# the footprint's bytes over the run's range as its length. Hand-written, as
# an outlined block's record (captures from byte 24): x[i] (k = 1) and y[2i]
# (k = 2: the odd elements keep their values through the copy in and back).
# Without whole=, and with a footprint reaching below the pointer, it stays
# on the CPU. Metal (a kernel in MSL) and CUDA (PTX) carry the kernel.
cat > "$W/whole.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
pointer malloc(u64 n);
class Fill : ParChunk
    {
    float* x;
    float* y;
    void run(void)
        {
        for (i64 i = lo; i < hi; i++)
            {
            x[i] = (float)(i % 1000);
            y[2 * i] = 3.0;
            }
        }
    ParChunk* copyChunk(void)
        {
        Fill* c = new Fill();
        c.x = x;
        c.y = y;
        return (ParChunk*)c;
        }
    u8* gpuSource(void)
        {
#if ARCH_arm64
        return "// xcpar msl size=40 lo=8 hi=16 buf=24:0:4 buf=32:1:4 FP WHOLE ops=2\n"
               "#include <metal_stdlib>\n"
               "using namespace metal;\n"
               "kernel void par_kernel(constant uchar* args [[buffer(0)]], constant long* span [[buffer(1)]], device float* buf_3 [[buffer(2)]], device float* buf_4 [[buffer(3)]], uint tid [[thread_position_in_grid]])\n"
               "{\n"
               "    long lo = span[0] + long(tid) * span[2];\n"
               "    long hi = min(lo + span[2], span[1]);\n"
               "    for (long i = lo; i < hi; i++) { buf_3[i] = float(i % 1000); buf_4[2 * i] = 3.0f; }\n"
               "}\n";
#else
        return "// xcpar ptx size=40 lo=8 hi=16 buf=24:0:4 buf=32:1:4 FP WHOLE ops=2 byval\n"
               ".version 7.0\n.target sm_52\n.address_size 64\n"
               ".visible .entry par_kernel(.param .align 8 .b8 args[40], .param .align 8 .b8 span[24], .param .u64 buf_3, .param .u64 buf_4)\n"
               "{\n"
               ".reg .b64 %lo, %hi, %end, %per, %t, %i, %r, %a, %b, %q;\n.reg .b32 %ct, %nt, %tx, %gid;\n.reg .f32 %f, %three;\n.reg .pred %p;\n"
               "mov.u32 %ct, %ctaid.x;\nmov.u32 %nt, %ntid.x;\nmov.u32 %tx, %tid.x;\nmad.lo.u32 %gid, %ct, %nt, %tx;\ncvt.u64.u32 %t, %gid;\n"
               "ld.param.u64 %lo, [span];\nld.param.u64 %end, [span+8];\nld.param.u64 %per, [span+16];\n"
               "mad.lo.u64 %lo, %t, %per, %lo;\nadd.s64 %hi, %lo, %per;\nmin.s64 %hi, %hi, %end;\n"
               "ld.param.u64 %a, [buf_3];\ncvta.to.global.u64 %a, %a;\nld.param.u64 %b, [buf_4];\ncvta.to.global.u64 %b, %b;\n"
               "mov.f32 %three, 0f40400000;\nmov.b64 %i, %lo;\n"
               "LOOP:\nsetp.ge.s64 %p, %i, %hi;\n@%p bra DONE;\nrem.s64 %r, %i, 1000;\ncvt.rn.f32.s64 %f, %r;\n"
               "shl.b64 %q, %i, 2;\nadd.s64 %q, %a, %q;\nst.global.f32 [%q], %f;\n"
               "shl.b64 %q, %i, 3;\nadd.s64 %q, %b, %q;\nst.global.f32 [%q], %three;\n"
               "add.s64 %i, %i, 1;\nbra.uni LOOP;\nDONE:\nret;\n}\n";
#endif
        }
    u8* parName(void)
        {
        return "whole";
        }
    }
i32 main(void)
    {
    i64 n = 1 << 21;
    Fill* f = new Fill();
    f.x = (float*)malloc((u64)(n * 4));
    f.y = (float*)malloc((u64)(n * 8));
    for (i64 i = 0; i < 2 * n; i++)
        f.y[i] = -1.0;
    for (i64 i = 0; i < n; i++)
        f.x[i] = -2.0;
    Par.run((ParChunk*)f, (i64)FROM, n);
    double s = 0.0;
    for (i64 i = 0; i < n; i++)
        s = s + (double)f.x[i] + (double)f.y[2 * i] + (double)f.y[2 * i + 1];
    // The last elements: a length one element short would drop them.
    Stdio.printf("%.1f %.1f %.1f %.1f %.1f %.1f\n", (double)f.x[12345], (double)f.y[24690], (double)f.y[24691],
                 (double)f.x[n - 1], (double)f.y[2 * n - 2], s);
    return 0;
    }
XC
wantw="345.0 3.0 -1.0 151.0 3.0 1051657280.0"
for v in whole none below; do
    case $v in
        whole) fp="fp=0:1:0:1 fp=1:2:0:1"; wh="whole=0 whole=1" ;;
        none)  fp="fp=0:1:0:1 fp=1:2:0:1"; wh="" ;;
        below) fp="fp=0:1:-1:1 fp=1:2:0:1"; wh="whole=0 whole=1" ;;
    esac
    sed "s/ FP / $fp /; s/ WHOLE / $wh /; s/(i64)FROM/(i64)0/" "$W/whole.xc" > "$W/whole_$v.xc"
    "$XC" -q -O2 -H . -o "$W/whole_$v" "$W/whole_$v.xc" > "$W/whole_$v.b" 2>&1 \
        || { echo "FAIL outlined-gpu: the whole= block ($v) does not build"; head -3 "$W/whole_$v.b"; fail=1; continue; }
    wruns="cpu gpu"
    [ "$PLAT" = linux ] && wruns="cpu cuda"
    for r in $wruns; do
        mkdir -p "$W/sw.$v.$r"
        env $(envFor "$r") XCC_SETTINGS_DIR="$W/sw.$v.$r" XC_PAR_REPORT=1 "$W/whole_$v" > "$W/o" 2> "$W/e"
        got=$(grep -v '^par:' "$W/o")
        [ "$got" = "$wantw" ] || { echo "FAIL outlined-gpu: the whole= block ($v, $r) gives '$got', wanted '$wantw'"; fail=1; }
        [ "$r" = cpu ] && continue
        [ "$PLAT" = linux ] && ! grep -q 'par: CUDA device' "$W/o" "$W/e" && continue
        if [ $v = whole ]; then
            grep -qE "whole: [0-9]+ items on the GPU" "$W/o" "$W/e" || { echo "FAIL outlined-gpu: the whole= block ($r) did not run on the GPU:"; grep -h 'par:' "$W/o" "$W/e" | head -4; fail=1; }
        else
            grep -qE "whole: [0-9]+ items on the GPU" "$W/o" "$W/e" && { echo "FAIL outlined-gpu: the block without a length ($v, $r) ran on the GPU"; fail=1; }
            grep -q "an array whose size is not known" "$W/o" "$W/e" || { echo "FAIL outlined-gpu: the block without a length ($v, $r) does not say why it stays on the CPU:"; grep -h 'par:' "$W/o" "$W/e" | head -3; fail=1; }
        fi
    done
done
# The run from 1000 on the tile queue: a tile worker lays the block out over
# [0, n), and its whole= lengths come from the run's own range.
sed "s/ FP / fp=0:1:0:1 fp=1:2:0:1 /; s/ WHOLE / whole=0 whole=1 /; s/(i64)FROM/(i64)1000/" "$W/whole.xc" > "$W/whole_lo.xc"
if "$XC" -q -O2 -H . -o "$W/whole_lo" "$W/whole_lo.xc" > "$W/whole_lo.b" 2>&1; then
    wantl="345.0 3.0 -1.0 151.0 3.0 1051151780.0"
    if [ "$PLAT" = osx ]; then sets="metal metal,cpu"; else sets="cuda cuda,cpu"; fi
    for set in "" $sets; do
        mkdir -p "$W/sl.$set"
        got=$(XC_PAR=gpu XC_PAR_WORKERS=$set XC_PAR_TILE_MB=1 XCC_SETTINGS_DIR="$W/sl.$set" "$W/whole_lo" 2>/dev/null)
        [ "$got" = "$wantl" ] || { echo "FAIL outlined-gpu: the whole= block from 1000 (workers '$set') gives '$got', wanted '$wantl'"; fail=1; }
    done
else
    echo "FAIL outlined-gpu: the whole= block from 1000 does not build"; head -3 "$W/whole_lo.b"; fail=1
fi
# C loops over malloc'd arrays: the runtime knows no block for them, and the
# results are clang's wherever the block runs.
if clang --version > /dev/null 2>&1; then
    cat > "$W/heap.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void init(float *x, float *y, long n)
{
    for (long i = 0; i < n; i++) {
        x[i] = (float)(i % 1000);
        y[i] = 1.0f;
    }
}
static void saxpy(float a, const float *x, float *y, long n)
{
    for (long i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}
static void five(const float *a, const float *b, const float *c, float *d, float *e, long n)
{
    for (long i = 0; i < n; i++) {
        d[i] = a[i] * b[i] - c[i];
        e[i] = a[i] + 2.0f * b[i] + c[i];
    }
}
int main(void)
{
    long n = 1 << 22;
    float *x = malloc(n * sizeof(float)), *y = malloc(n * sizeof(float));
    float *d = malloc(n * sizeof(float)), *e = malloc(n * sizeof(float));
    init(x, y, n);
    saxpy(2.0f, x, y, n);
    five(x, y, x, d, e, n);
    double t = 0;
    for (long i = 0; i < n; i++)
        t += x[i] + y[i] + d[i] + e[i];
    printf("%.1f %.1f %.1f %.1f %.1f\n", x[12345], y[777], d[4242], e[99], t);
    return 0;
}
C
    if [ "$PLAT" = osx ] || [ -f /usr/include/stdio.h ]; then
        clang -O2 -o "$W/heap.ref" "$W/heap.c" 2>/dev/null && want=$("$W/heap.ref")
        "$XC" -q -O3 -H . -o "$W/heap" "$W/heap.c" > "$W/heap.b" 2>&1 || { echo "FAIL outlined-gpu: heap.c does not build"; head -3 "$W/heap.b"; fail=1; }
        if [ -x "$W/heap" ] && [ -n "${want:-}" ]; then
            for r in $runs; do
                mkdir -p "$W/sh.$r"
                got=$(env $(envFor "$r") XCC_SETTINGS_DIR="$W/sh.$r" "$W/heap" 2>/dev/null)
                [ "$got" = "$want" ] || { echo "FAIL outlined-gpu: heap.c ($r) gives '$got', clang's '$want'"; fail=1; }
            done
        fi
    fi
else
    echo "outlined-gpu: no clang, the C case skipped"
fi
[ $fail = 0 ] && echo "--- outlined-gpu: pass ---" || echo "--- outlined-gpu: FAIL ---"
exit $fail
