// par_slices.xc — slices of one big array written by a par block, one slice at
// a time through `stack + k*n`, then the whole array read by another block
// (2026-10-26, reported by the Astronomancy stream). Under CUDA the whole
// array's copy kept on the GPU was taken for current: a write through a
// pointer INTO a block did not move the block's generation, so the combine saw
// only the first slice (999 + 4.5 came out 99.9).
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
    {
    u32 n = 300000;      // 1.2 MB slices: from a megabyte, blocks are pinned
    u32 frames = 10;
    float* stack = new float[n * frames];
    u16* raw = new u16[n];
    for (u32 i = 0; i < n; i = i + 1)
        raw[i] = (u16)(i % 1000);
    for (u32 k = 0; k < frames; k = k + 1)
        {
        float* slot = stack + k * n;
        u32 add = k;
        par decode
            {
            for (u32 i in 0..n)
                slot[i] = (float)raw[i] + (float)add;
            }
        }
    float* out = new float[n];
    par combine
        {
        for (u32 i in 0..n)
            {
            float s = 0.0;
            for (u32 k = 0; k < frames; k = k + 1)
                s = s + stack[k * n + i];
            out[i] = s / (float)frames;
            }
        }
    Stdio.printf("%.1f %.1f\n", (double)out[999], (double)out[n - 1]);
    return 0;
    }
