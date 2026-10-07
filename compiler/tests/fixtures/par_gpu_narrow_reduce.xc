// par_gpu_narrow_reduce.xc — reductions of 8- and 16-bit values and bools in
// a `par` block: a wrapping u8 sum, an i8 max, an i16 min, a u16 xor, and a
// bool "any" and "all". On Vulkan and WebGPU each thread's partial is a
// 32-bit slot whose low bytes the host folds; the results must be the CPU's.
#import "Stdio.xc"
#import "Par.xc"

#define N 5000

i32 main(void)
    {
    u8 sum8 = (u8)7;
    i8 max8 = (i8)-128;
    i16 min16 = (i16)32767;
    u16 x16 = (u16)0x1234;
    bool any = false;
    bool all = true;
    par narrow :reduce(+ sum8) :reduce(max max8) :reduce(min min16) :reduce(^ x16) :reduce(| any) :reduce(& all)
        {
        for (u32 i in 0..N)
            {
            u32 h = i * (u32)2654435761;
            h = h ^ (h >> (u32)15);
            sum8 = sum8 + (u8)h;
            i8 s8 = (i8)(h >> (u32)8);
            if (s8 > max8)
                max8 = s8;
            i16 s16 = (i16)(h >> (u32)3);
            if (s16 < min16)
                min16 = s16;
            x16 = x16 ^ (u16)(h >> (u32)13);
            any = any | (h % (u32)4999 == (u32)17);
            all = all & (h % (u32)977 != (u32)3);
            }
        }
    Stdio.printf("sum8 %u max8 %d min16 %d x16 %04x any %d all %d\n", (u32)sum8, (i32)max8, (i32)min16, (u32)x16,
                 any ? 1 : 0, all ? 1 : 0);
    return (i32)0;
    }
