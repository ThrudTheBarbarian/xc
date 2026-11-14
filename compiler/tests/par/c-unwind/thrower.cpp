// The C++ half: cb throws at 7, run catches it after apply (xcc's, in
// apply.c) and checks that its own values, kept in callee-saved registers
// across the call, survived the unwinding (1133).
#include <cstdio>
#include <stdexcept>
extern "C" long apply(long n);
extern "C" long cb(long i) { if (i == 7) throw std::runtime_error("seven"); return i; }
static long boom(long i) { if (i == 7) throw std::runtime_error("seven"); return i; }
__attribute__((noinline)) static long run(long a, long b, long c, long d, long e, long f, long g, long h, long k, long m)
{
    long x1 = a * 3, x2 = b * 5, x3 = c * 7, x4 = d * 11, x5 = e * 13, x6 = f * 17, x7 = g * 19, x8 = h * 23, x9 = k * 29, x10 = m * 31;
    try { apply(100); }
    catch (const std::exception&) { return x1 + x2 + x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10; }
    return -1;
}
int main()
{
    volatile long seed = 1;
    long r = run(seed, seed + 1, seed + 2, seed + 3, seed + 4, seed + 5, seed + 6, seed + 7, seed + 8, seed + 9);
    std::printf("%ld %s\n", r, r == 3 + 10 + 21 + 44 + 65 + 102 + 133 + 184 + 261 + 310 ? "ok" : "CORRUPT");
    return 0;
}
