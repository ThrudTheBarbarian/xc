// bench_time — monotonic elapsed microseconds. See bench_time.xc; both halves
// call the same primitive so they are measured identically, and both take the
// Windows branch on Windows, where clock_gettime does not exist.
#ifndef BENCH_TIME_H
#define BENCH_TIME_H
#include <stdint.h>
#if defined(_WIN32)
#include <windows.h>
static inline int64_t bench_now_us(void)
    {
    LARGE_INTEGER c, f;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (c.QuadPart / f.QuadPart) * 1000000
         + ((c.QuadPart % f.QuadPart) * 1000000) / f.QuadPart;
    }
#else
#include <time.h>
static inline int64_t bench_now_us(void)
    {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + (int64_t)ts.tv_nsec / 1000;
    }
#endif
#endif
