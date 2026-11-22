// cpp-handlers.sh: fill invokes runtime_error's constructor with a string
// global's address (made before the call); allocsum's try catches it. xcc
// takes every function on arm64 macOS.
#include <cstdio>
#include <stdexcept>

__attribute__((noinline)) static long fill(int* p, int k) {
    if (k % 7 == 3)
        throw std::runtime_error("seven");
    long s = 0;
    for (int i = 0; i < 64; i++)
        s += p[i] = i * k;
    return s;
}

__attribute__((noinline)) long allocsum(int n) {
    long t = 0;
    for (int k = 0; k < n; k++) {
        int* p = new int[64];
        try {
            t += fill(p, k);
        } catch (const std::runtime_error&) {
            t -= 1000;
        }
        delete[] p;
    }
    return t;
}

int main() {
    printf("%ld\n", allocsum(50));
    return 0;
}
