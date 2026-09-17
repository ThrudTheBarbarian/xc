// bench_time — monotonic elapsed microseconds. See bench_time.xc; both halves
// call clock_gettime(CLOCK_MONOTONIC) so they are measured identically.
#ifndef BENCH_TIME_H
#define BENCH_TIME_H
#include <time.h>
#include <stdint.h>
static inline int64_t bench_now_us(void)
    {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + (int64_t)ts.tv_nsec / 1000;
    }
#endif
