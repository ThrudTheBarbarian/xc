// par_gpu_narrow_memory.xc — `par` blocks over arrays of 8- and 16-bit values
// and bools, and with captured bools and bytes. On a Vulkan GPU these are
// bound as 32-bit words: a load shifts and masks, a store updates its bits with
// atomic and/or, because the work items either side write the other bytes of
// the same word at the same time. Every result must be the CPU's.
#import "Stdio.xc"
#import "Par.xc"

#define N 1003

u8 bytes[N];
i8 signedBytes[N];
u16 halves[N];
bool flags[N];
u8 table[N];        // a global the block reads

i32 main(void)
    {
    for (u32 i in 0..N)
        {
        signedBytes[i] = (i8)((i32)(i * (u32)37) - 128);
        table[i] = (u8)(i * (u32)11);
        }
    bool invert = true;
    u8 bias = (u8)200;
    u32 sum = (u32)0;
    par fill :reduce(+ sum)
        {
        for (u32 i in 0..N)
            {
            bytes[i] = (u8)(i * (u32)7) + bias;              // wraps at 8 bits
            halves[i] = (u16)(i * (u32)977);                 // wraps at 16 bits
            bool odd = (i & (u32)1) == (u32)1;
            flags[i] = invert ? !odd : odd;
            i32 s = (i32)signedBytes[i];                     // sign-extended
            sum = sum + (u32)(s + (i32)128) + (u32)table[i];
            }
        }
    u32 b = (u32)0;
    u32 h = (u32)0;
    u32 f = (u32)0;
    for (u32 i in 0..N)
        {
        b = b * (u32)31 + (u32)bytes[i];
        h = h * (u32)31 + (u32)halves[i];
        if (flags[i])
            f = f + i;
        }
    Stdio.printf("bytes %08x halves %08x flags %u sum %u\n", b, h, f, sum);
    Stdio.printf("bytes[0..3] %u %u %u %u, halves[1002] %u, flags[0..1] %d %d\n", (u32)bytes[0], (u32)bytes[1],
                 (u32)bytes[2], (u32)bytes[3], (u32)halves[1002], (i32)flags[0], (i32)flags[1]);
    return (i32)0;
    }
