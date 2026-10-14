// par_narrow_fp.xc — a `par` block that converts a NARROW integer (u8/u16) to
// float. The PTX back end refused a narrow int<->float conversion and dropped
// the whole kernel to a silent SPIR-V fallback, so an NVIDIA card driven
// through CUDA could not run the block — nor tile it across two. The shape
// arises naturally: `(float)W` for a `#define W` that fits in 16 bits is a
// `(float)<u16>`. This pins that the kernel is still emitted for CUDA (a
// narrow conversion no longer sinks it), byte-identical in both compilers via
// parspv-diff, and computes the same answer as the scalar path. W = 256 is a
// power of two, so b/256 is exact in float and b/256*256 is exactly b.
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 4096
#define W 256

u32 out[N];

i32 main(void)
{
    u32 total = (u32)0;
    par t :reduce(+ total)
    {
        for (u32 i in 0..N)
        {
            u16 w = (u16)W;
            u8 b = (u8)(i % (u32)W);
            float f = (float)b / (float)w;    // (float)<u8> over (float)<u16>
            out[i] = (u32)(f * 256.0f);
            total = total + out[i];
        }
    }
    Stdio.printf("%u\n", total);
    return 0;
}
