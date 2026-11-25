//xtc-na: xt6502, m68k — par has no threads there
// par_float_names.xc — `par` blocks over f32 data. f32 is float, so the
// blocks' element types and GPU kernel are the ones a block written with float
// gets: one block runs on the CPU and the other on the GPU where there is one.
// Every value is a small multiple of a power of two, so both give exact
// results.
#import "Stdio.xc"
#import "Par.xc"

#define N 4096

f32 src[N];
f32 onCpu[N];
float onGpu[N];

i32 main(void)
{
    for (u32 i in 0..N)
        src[i] = (f32)(i % 64) * 0.25;
    par scaleCpu :device(cpu)
    {
        for (u32 i in 0..N)
        {
            f32 v = src[i];
            onCpu[i] = v * 2 + 0.5;
        }
    }
    par scaleGpu :device(gpu)
    {
        for (u32 i in 0..N)
        {
            float v = src[i];
            f32 w = v * 2;
            onGpu[i] = w + 0.5;
        }
    }
    u32 bad = 0;
    f64 total = 0;
    for (u32 i in 0..N)
    {
        if (onCpu[i] != onGpu[i])
            bad = bad + 1;
        total = total + (f64)onCpu[i] * 0.5;
    }
    Stdio.printf("differ %d first %f last %f total %f\n", (i32)bad, onCpu[1], onGpu[N - 1], total);
    return 0;
}
