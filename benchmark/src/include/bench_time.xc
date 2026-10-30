// bench_time — monotonic elapsed microseconds, for timing inside the program.
// clock_gettime(CLOCK_MONOTONIC) is the same primitive the Objective-C half
// calls, so the two halves are measured identically.
// Windows has no clock_gettime; QueryPerformanceCounter is its monotonic
// high-resolution clock.
#if OS_windows
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* freq);
#else
// The same signature as the library's own declarations (ParDevice.xc,
// RunLoop.xc): a C function has one, and a program importing both must agree.
i32 clock_gettime(i32 clk, pointer ts);
#endif

struct BenchSpec { i64 sec; i64 nsec; }

i64 bench_now_us(void)
    {
#if OS_windows
    i64 c = (i64)0;
    i64 f = (i64)1;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (c / f) * (i64)1000000 + ((c % f) * (i64)1000000) / f;
#else
    BenchSpec ts;
    // CLOCK_MONOTONIC is 6 on Darwin and 1 on Linux; 6 on Linux is
    // CLOCK_MONOTONIC_COARSE, which moves in 4 ms ticks (arm64 Linux timed
    // with it until 2026-10-30). ARCH_x86_64 keeps a compiler without the
    // OS_ names right on x86-64 Linux.
#if OS_linux || ARCH_x86_64
    clock_gettime((i32)1, (pointer)&ts);
#else
    clock_gettime((i32)6, (pointer)&ts);
#endif
    return (ts.sec * (i64)1000000) + (ts.nsec / (i64)1000);
#endif
    }
