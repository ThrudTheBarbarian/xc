// bench_time — monotonic elapsed microseconds. See bench_time.xc; every
// version calls clock_gettime(CLOCK_MONOTONIC) so they are measured identically.
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func bench_now_us() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1000
}
