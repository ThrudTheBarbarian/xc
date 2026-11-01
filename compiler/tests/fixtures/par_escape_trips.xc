// par_escape_trips.xc — a GPU kernel's escape loop runs several trips per exit
// test, and every lane still ends where the plain loop ends it (2026-11-01).
//
// The kernel copy of a `while` whose test and body are pure runs eight trips
// per test, a lane whose test has failed keeping its values by selects
// (XTIROptGpuEscapeTrips / gpuEscapeTrips). Lanes here leave on the first
// trip, part-way through, and at a cap of 37 (not a multiple of eight); the
// counts and the final values must be the CPU's exactly.

#import "Stdio.xc"
#import "Par.xc"

#define N 4096
u32 counts[N];
float ends[N];

i32 main(void)
    {
    u32 total = (u32)0;
    par esc :reduce(+ total)
        {
        for (u32 i in 0..(u32)N)
            {
            float cx = (float)(i % (u32)64) * (3.0f / 64.0f) - 2.0f;
            float cy = (float)(i / (u32)64) * (3.0f / 64.0f) - 1.5f;
            float x = 0.0f;
            float y = 0.0f;
            u32 k = (u32)0;
            while (k < (u32)37 && x * x + y * y < 4.0f)
                {
                float xt = x * x - y * y + cx;
                y = 2.0f * x * y + cy;
                x = xt;
                k = k + (u32)1;
                }
            counts[i] = k;
            ends[i] = x;
            total = total + k;
            }
        }
    // Lanes that leave on the first trip (0), part-way (615, 679: not on a
    // multiple of eight) and at the cap (2080). Three decimals: lane 615 ends
    // at -0.33995, where a device's contracted multiply-adds land either side
    // of a fourth one (-0.3399 on llvmpipe and the Mac, -0.3400 on RADV and
    // the x86-64 CPU).
    Stdio.printf("total %u k %u %u %u %u x %.3f %.3f\n", total, counts[(u32)0], counts[(u32)615],
                 counts[(u32)679], counts[(u32)2080], (double)ends[(u32)615], (double)ends[(u32)2080]);
    return (i32)0;
    }
