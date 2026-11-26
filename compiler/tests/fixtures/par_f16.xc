//xtc-na: xt6502, m68k — par has no threads there
//xtc-warn: because it computes in f16, bf16, f8 or f4, which GPU kernels do not take yet
// par_f16.xc — `par` blocks over f16 and bf16 arrays. Each element's
// operations round to the element type as anywhere else. GPU kernels do not
// take the 16-bit floats yet, so the block marked for the GPU runs on the CPU,
// and the compiler says why; XC_PAR_REPORT=1 shows where each block ran. The
// values are short binary fractions, so the results are exact.
#import "Stdio.xc"
#import "Par.xc"

#define N 4096

f16 src[N];
f16 onCpu[N];
f16 onGpu[N];
bf16 wide[N];

i32 main(void)
{
    for (u32 i in 0..N)
        src[i] = (f16)(i % 64) * 0.25;
    par scaleCpu :device(cpu)
    {
        for (u32 i in 0..N)
        {
            f16 v = src[i];
            onCpu[i] = v * 2 + 0.5;
        }
    }
    par scaleGpu :device(gpu)
    {
        for (u32 i in 0..N)
        {
            f16 v = src[i];
            onGpu[i] = v * 2 + 0.5;
            wide[i] = (bf16)v * 3;
        }
    }
    u32 bad = 0;
    f32 total = 0;
    for (u32 i in 0..N)
    {
        if (onCpu[i] != onGpu[i])
            bad = bad + 1;
        total = total + wide[i];
    }
    Stdio.printf("differ %d first %f last %f\n", (i32)bad, onCpu[1], onGpu[N - 1]);
    Stdio.printf("bf16 %f %f total %f\n", wide[5], wide[N - 1], total);
    return 0;
}
