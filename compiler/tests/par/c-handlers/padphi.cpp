// cpp-handlers.sh: a catch that reads a value which differs by the call that
// threw, so its landing pad starts with a phi (each invoke gets a pad of its
// own). xcc takes every function on arm64 macOS.
#include <cstdio>
#include <stdexcept>

__attribute__((noinline)) static long step(long i) {
    if (i % 5 == 4)
        throw std::runtime_error("five");
    return i * i;
}

__attribute__((noinline)) long tally(long n) {
    long t = 0;
    for (long i = 0; i < n; i++) {
        long r = 1;
        try {
            r = step(i);
            r = r + step(i + 1);
            r = r * 2 + step(i + 2);
        } catch (const std::runtime_error&) {
            t -= r;
            continue;
        }
        t += r;
    }
    return t;
}

int main() {
    printf("%ld\n", tally(100));
    return 0;
}
