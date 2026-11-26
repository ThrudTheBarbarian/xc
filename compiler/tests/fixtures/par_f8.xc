//xtc-na: xt6502, m68k — par has no threads there
// par_f8.xc — `par` blocks over f8 (E4M3), f8:pack(e5m2) and f8:pack(ue8m0)
// arrays. Each element's operations round to the element type as anywhere
// else, saturating at 448 in E4M3, on the CPU and on the GPU alike: a GPU
// kernel converts each value in the kernel. XC_PAR_REPORT=1 shows where each
// block ran. The values are short binary fractions, so the results are exact.
#import "Stdio.xc"
#import "Par.xc"

#define N 4096

f8 src[N];
f8 onCpu[N];
f8 onGpu[N];
f8:pack(e5m2) wide[N];
f8:pack(ue8m0) scale[N];

i32 main(void)
{
    for (u32 i in 0..N)
        src[i] = (f8)(i % 64) * 0.25;
    par scaleCpu :device(cpu)
    {
        for (u32 i in 0..N)
        {
            f8 v = src[i];
            onCpu[i] = v * 16 + 0.5;
        }
    }
    par scaleGpu :device(gpu)
    {
        for (u32 i in 0..N)
        {
            f8 v = src[i];
            onGpu[i] = v * 16 + 0.5;
            wide[i] = (f8:pack(e5m2))v * 3;
            scale[i] = (f8:pack(ue8m0))(f32)(i % 16 + 1);
        }
    }
    u32 bad = 0;
    f32 total = 0;
    f32 scales = 0;
    for (u32 i in 0..N)
    {
        if (onCpu[i] != onGpu[i])
            bad = bad + 1;
        total = total + wide[i];
        scales = scales + (f32)scale[i];
    }
    Stdio.printf("differ %d first %f last %f\n", (i32)bad, onCpu[1], onGpu[N - 1]);
    Stdio.printf("e5m2 %f %f total %f\n", wide[5], wide[N - 1], (f64)total);
    Stdio.printf("ue8m0 %f %f sum %f\n", scale[2], scale[5], (f64)scales);
    return 0;
}
