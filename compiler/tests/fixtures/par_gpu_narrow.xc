//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_gpu_narrow.xc — 8- and 16-bit values in a `par` block that can run on
// the GPU (XC_PAR=gpu). A GPU keeps them in 32-bit registers; the kernel keeps
// each one extended by its own signedness, so a signed compare (v < -10), a
// zero-extension of a negative i8 ((u8)v) and a sign-extension ((i32)v) all
// give the CPU's answers.
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (256 * 1024)

i8 vals[SIZE];
i16 wide[SIZE];
u32 asByte[SIZE];

i32 main(void)
{
    for (u32 i in 0..SIZE)
        {
        vals[i] = (i8)(i * (u32)37);
        wide[i] = (i16)(i * (u32)7919);
        }
    u32 negatives = (u32)0;
    u32 small = (u32)0;
    i32 total = (i32)0;
    par narrow :reduce(+ negatives) :reduce(+ small) :reduce(+ total)
        {
        for (u32 i in 0..SIZE)
            {
            i8 v = vals[i];
            if (v < (i8)-10)
                negatives = negatives + (u32)1;
            if (wide[i] > (i16)-1000 && wide[i] < (i16)1000)
                small = small + (u32)1;
            asByte[i] = (u32)(u8)v;
            total = total + (i32)v;
            }
        }
    u32 bytes = (u32)0;
    for (u32 i in 0..SIZE)
        bytes = bytes + asByte[i];
    Stdio.printf("negatives %u, small %u, total %d, bytes %u\n", negatives, small, total, bytes);
    return 0;
}
