// bench_time — monotonic elapsed microseconds, for timing inside the program.
// clock_gettime(CLOCK_MONOTONIC) is the same primitive the Objective-C half
// calls, so the two halves are measured identically.
i32 clock_gettime(i32 clk, u8* ts);

struct BenchSpec { i64 sec; i64 nsec; }

i64 bench_now_us(void)
    {
    BenchSpec ts;
    // CLOCK_MONOTONIC is 6 on Darwin and 1 on Linux.
#if ARCH_x86_64
    clock_gettime((i32)1, (u8*)&ts);
#else
    clock_gettime((i32)6, (u8*)&ts);
#endif
    return (ts.sec * (i64)1000000) + (ts.nsec / (i64)1000);
    }
