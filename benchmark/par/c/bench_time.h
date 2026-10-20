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
