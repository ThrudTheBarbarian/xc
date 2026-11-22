// cpp-handlers.sh: a virtual call in a try (an invoke through a pointer),
// whose callee throws now and then, and a call through a function pointer in
// a try. xcc takes every function on arm64 macOS.
#include <cstdio>
#include <stdexcept>

struct Op {
    virtual ~Op() {}
    virtual long apply(long x) const = 0;
};
struct Add : Op {
    long k;
    explicit Add(long k) : k(k) {}
    long apply(long x) const override {
        if (x % 13 == 12)
            throw std::range_error("add");
        return x + k;
    }
};
struct Mul : Op {
    long k;
    explicit Mul(long k) : k(k) {}
    long apply(long x) const override {
        if (x % 17 == 16)
            throw std::range_error("mul");
        return x * k;
    }
};

static long twice(long x) {
    if (x % 19 == 18)
        throw std::range_error("twice");
    return 2 * x;
}

static Op* volatile ops[2];
static long (*volatile fn)(long);

__attribute__((noinline)) long run(Op* const* v, long (*f)(long), long n) {
    long t = 0;
    for (long i = 0; i < n; i++) {
        try {
            t += v[i & 1]->apply(i);
        } catch (const std::range_error&) {
            t -= 5;
        }
        try {
            t += f(i);
        } catch (const std::range_error&) {
            t -= 3;
        }
    }
    return t;
}

int main() {
    Add a(7);
    Mul m(3);
    ops[0] = &a;
    ops[1] = &m;
    fn = twice;
    Op* v[2] = { ops[0], ops[1] };
    printf("%ld\n", run(v, fn, 200));
    return 0;
}
