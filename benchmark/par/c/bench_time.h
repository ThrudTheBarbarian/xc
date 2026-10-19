/* bench_time.h — the par benchmarks' clock in C, as bench_time.xc is in xc:
   microseconds of a monotonic clock. */
#include <time.h>
static long long bench_now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
