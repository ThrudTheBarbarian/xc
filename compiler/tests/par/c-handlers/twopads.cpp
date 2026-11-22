// cpp-handlers.sh: two objects with destructors, each live across a call
// that may throw, so clang's passes merge the cleanups' landing pads into one
// resume of a phi of the pad pair (`common.resume.op`). xcc takes walk on
// arm64 macOS.
#include <cstdio>
#include <stdexcept>

static long dtors = 0;
struct Guard {
    long k;
    explicit Guard(long k) : k(k) {}
    ~Guard() { dtors += k; }
};

__attribute__((noinline)) static long step(long i) {
    if (i % 11 == 10)
        throw std::runtime_error("eleven");
    return i * 3;
}

__attribute__((noinline)) long walk(long n) {
    long t = 0;
    for (long i = 0; i < n; i++) {
        Guard a(1);
        t += step(i);
        Guard b(100);
        t += step(i + 1);
    }
    return t;
}

int main() {
    long r = 0;
    for (long n = 1; n < 30; n++) {
        try {
            r += walk(n);
        } catch (const std::runtime_error&) {
            r -= 7;
        }
    }
    printf("%ld %ld\n", r, dtors);
    return 0;
}
