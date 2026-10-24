/* bench_time.h — the par benchmarks' clock in C, as bench_time.xc is in xc:
   microseconds of a monotonic clock (on Windows, C11's timespec_get: the
   Microsoft C library has no clock_gettime). */
#include <time.h>
static long long bench_now_us(void)
{
    struct timespec ts;
#ifdef _WIN32
    timespec_get(&ts, TIME_UTC);
#else
    clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
    return (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
/* The timed work must stay between the two clock reads.  It does the same
   thing each repeat, so a compiler may compute it once outside them (GCC -O3
   does).  bench_zero() is a 0 it cannot know, read where the timed loop
   starts, so the work cannot begin before the first read; bench_keep() stores
   the result where it cannot see, before the second, so it cannot end after. */
static volatile unsigned bench_zero_v;
static volatile unsigned long long bench_keep_v;
#define bench_zero() (bench_zero_v)
#define bench_keep(x) (bench_keep_v = (unsigned long long)(x))
/* BENCH_SCALE multiplies a program's work by 1 (the default), 4 or 16, as a
   build option (-DBENCH_SCALE=4): enough for a big GPU, or two, to fill.  An
   image's side, or N in O(N^2), grows by BENCH_SIDE, 1, 2 or 4. */
#ifndef BENCH_SCALE
#define BENCH_SCALE 1
#endif
#if BENCH_SCALE != 1 && BENCH_SCALE != 4 && BENCH_SCALE != 16
#error BENCH_SCALE is 1, 4 or 16
#endif
#define BENCH_SIDE (BENCH_SCALE == 16 ? 4 : BENCH_SCALE == 4 ? 2 : 1)
