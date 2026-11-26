// Counted loops whose count starts below zero, in a try (a call that may
// throw keeps clang's passes from rotating the loop, so its exit tests
// `b == n` in the header): from the constant -2, and from a start known only
// at run time (argc - 4, so -3 here). Each must run every iteration.
#include <cstdio>
#include <stdexcept>

__attribute__((noinline)) long dv(long a, long b)
{
    if (b == 0)
        throw std::runtime_error("divide by zero");
    return a / b;
}

__attribute__((noinline)) long from(long lo, long hi)
{
    long q = 0;
    for (long b = lo; b < hi; b++) {
        try {
            q += dv(1000 + b, b);
        } catch (const std::runtime_error&) {
            q += 1;
        }
    }
    return q;
}

int main(int argc, char**)
{
    long q = 0;
    for (long b = -2; b <= 2; b++) {
        try {
            q += dv(1000 + b, b);
        } catch (const std::runtime_error&) {
            q += 1;
        }
    }
    std::printf("%ld %ld\n", q, from(argc - 4, 3));
    return 0;
}
