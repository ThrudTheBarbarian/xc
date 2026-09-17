// bench_time — monotonic elapsed microseconds, for timing inside the program.
// clock_gettime(CLOCK_MONOTONIC) is the same primitive the Objective-C half
// calls, so the two halves are measured identically.
i32 clock_gettime(i32 clk, u8* ts);

struct BenchSpec { i64 sec; i64 nsec; }

i64 bench_now_us(void)
    {
    BenchSpec ts;
    clock_gettime((i32)6, (u8*)&ts);           // CLOCK_MONOTONIC on Darwin
    return (ts.sec * (i64)1000000) + (ts.nsec / (i64)1000);
    }
