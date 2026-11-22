// cpp-handlers.sh: a variadic function that may throw (say) called while an
// object with a destructor is live, so the call is an invoke; on arm64 macOS
// its doubles go on the stack as for any variadic call.
#include <cstdarg>
#include <cstdio>

static long closed = 0;
struct Log {
    long id;
    explicit Log(long id) : id(id) {}
    ~Log() { closed += id; }
};

__attribute__((noinline)) void say(const char* f, ...) {
    if (f[0] == '!')
        throw 1;
    va_list ap;
    va_start(ap, f);
    std::vprintf(f, ap);
    va_end(ap);
}

__attribute__((noinline)) void report(double a, double b, long n) {
    Log l(n);
    for (long i = 0; i < n; i++)
        a = a * 1.5 + b;
    say("%.3f %.3f %ld\n", a, b, n);
}

int main() {
    report(1.25, 0.5, 3);
    report(2.0, -1.0, 4);
    std::printf("%ld\n", closed);
    return 0;
}
