// par_gpu_writes_all.xc — a block that overwrites a global array whole is not
// copied to the device first (gpuWritesAll), one that writes only half of one
// is, and one that reads what it writes is. The untouched half must keep its
// 7s, and every sum must be the CPU's.
#import "Stdio.xc"
#import "Par.xc"
u32 whole[4096];
u32 half[4096];
u32 readit[4096];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i in 0..4096) { whole[i] = 7; half[i] = 7; readit[i] = i; }
    u32 k = (u32)argc;
    par :reduce(+ k)
        {
        for (u32 i in 0..4096)
            {
            whole[i] = i * 3;
            }
        }
    par
        {
        for (u32 i in 0..2048)
            {
            half[i] = i;
            }
        }
    par
        {
        for (u32 i in 0..4096)
            {
            readit[i] = readit[i] + 1;
            }
        }
    u32 a = (u32)0; u32 b = (u32)0; u32 c = (u32)0;
    for (u32 i in 0..4096) { a = a + whole[i]; b = b + half[i]; c = c + readit[i]; }
    Stdio.printf("%u %u %u %u\n", a, b, c, half[3000]);
    return 0;
    }
