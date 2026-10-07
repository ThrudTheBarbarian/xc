// par_gpu_accuracy.xc — float division and square root in a `par` block whose
// goal is accuracy. Vulkan and WebGPU allow their own division 2.5 ulp and
// their square root more, so there they are done in integer arithmetic
// (ParSoftFloat.xc), correctly rounded; every result must be the CPU's, bit
// for bit. The values stay normal: Apple GPUs flush subnormals to zero.
// soft_float_rn.xc checks the helpers' subnormals and halfway cases.
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"

#define N 20000

float quo[N];
float root[N];

// A float spread over 70 binades, 2^-35 to 2^34: a hashed significand, so
// quotients and roots stay normal.
float spread(u32 i)
    {
    u32 h = i * (u32)2654435761;
    h = h ^ (h >> (u32)13);
    u32 e = (u32)(h % (u32)70) + (u32)92;
    u32 bits = (e << (u32)23) | ((h * (u32)40503) & (u32)0x7FFFFF);
    return *(float*)&bits;
    }

i32 main(void)
    {
    float a[N];
    float b[N];
    for (u32 i in 0..N)
        {
        a[i] = spread(i);
        b[i] = spread(i + (u32)N);
        }
    par careful :goal(accuracy)
        {
        for (u32 i in 0..N)
            {
            quo[i] = a[i] / b[i];
            root[i] = Math.sqrt(a[i]);
            }
        }
    u32 hq = (u32)0;
    u32 hr = (u32)0;
    for (u32 i in 0..N)
        {
        float q = quo[i];
        float r = root[i];
        hq = hq * (u32)31 + *(u32*)&q;
        hr = hr * (u32)31 + *(u32*)&r;
        }
    Stdio.printf("quotients %08x roots %08x\n", hq, hr);
    return (i32)0;
    }
