// Structs passed by value on x86-64 System V's stack (`byval`): each case
// prints a checksum of what the callee saw. Run against clang.
//   A: 24 bytes, integer registers left (it goes on the stack anyway)
//   B: 40 bytes after six integers (registers used up) and ten doubles
//      (xmm used up, two doubles on the stack before and after it)
//   C: 32 bytes aligned 16 (an offset of 16 in the outgoing area), after
//      one 8-byte stack word that makes the padding necessary
//   D: aligned 32: over-aligned, left to clang, still right
//   E: to a function clang compiles (an alloca of run-time size), which
//      passes it on to one xcc compiles (fg)
//   F: to a variadic function (left to clang), read back with va_arg
//   G: in a loop calling it, built with --par-style=auto as well (the
//      loop builds the struct in a slot, so it stays serial)
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

struct S24 { long a, b, c; };
struct S40 { long a; double b; int c; long d, e; };
struct S16 { long a, b, c; long d; } __attribute__((aligned(16)));
struct S32 { long a, b; } __attribute__((aligned(32)));

__attribute__((noinline)) long fa(int x, struct S24 s, int y)
{
    return x * 1000 + s.a * 100 + s.b * 10 + s.c + y * 7;
}

__attribute__((noinline)) double fb(long i1, long i2, long i3, long i4, long i5, long i6,
                                    double d1, double d2, double d3, double d4, double d5,
                                    double d6, double d7, double d8, double d9,
                                    struct S40 s, double d10, long i7)
{
    return (double)(i1 + 2 * i2 + 3 * i3 + 4 * i4 + 5 * i5 + 6 * i6 + 7 * i7)
         + d1 + d2 * 2 + d3 * 3 + d4 * 4 + d5 * 5 + d6 * 6 + d7 * 7 + d8 * 8 + d9 * 9 + d10 * 10
         + (double)s.a * 11 + s.b * 13 + (double)s.c * 17 + (double)s.d * 19 + (double)s.e * 23;
}

__attribute__((noinline)) long fc(long i1, long i2, long i3, long i4, long i5, long i6, long i7, struct S16 s, long i8)
{
    return i1 + i2 + i3 + i4 + i5 + i6 + i7 * 3 + s.a * 5 + s.b * 7 + s.c * 11 + s.d * 13 + i8 * 17;
}

__attribute__((noinline)) long fd(int x, struct S32 s)
{
    return x + s.a * 3 + s.b * 5;
}

__attribute__((noinline)) long fg(struct S24 s);

__attribute__((noinline)) long fe(struct S24 s, int n)
{
    char* buf = __builtin_alloca(n);
    memset(buf, (int)s.a, n);
    return buf[n - 1] + s.b + s.c + fg(s);
}

__attribute__((noinline)) long ff(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    long t = 0;
    for (int i = 0; i < n; i++) {
        struct S24 s = va_arg(ap, struct S24);
        t = t * 31 + s.a + s.b * 2 + s.c * 3;
    }
    va_end(ap);
    return t;
}

__attribute__((noinline)) long fg(struct S24 s)
{
    return s.a * s.b - s.c;
}

// D's and F's calls: each leaves its caller to clang, so not main.
__attribute__((noinline)) static long dcall(void)
{
    struct S32 d = {14, 15};
    return fd(3, d);
}

__attribute__((noinline)) static long fcall(struct S24 a)
{
    struct S24 a2 = {4, 5, 6};
    return ff(2, a, a2);
}

static long out[4096];

int main(int argc, char** argv)
{
    struct S24 a = {argc, 2, 3};
    struct S40 b = {5, 6.5, 7, 8, 9};
    struct S16 c = {10, 11, 12, 13};
    long h = fa(1, a, 2);
    double g = fb(1, 2, 3, 4, 5, 6, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, b, 10.5, 7);
    long k = fc(1, 2, 3, 4, 5, 6, 7, c, 8);
    long m = dcall();
    long e = fe(a, 5 + argc);
    long f = fcall(a);
    for (int i = 0; i < 4096; i++) {
        struct S24 s = {i, argc + i % 7, i % 3};
        out[i] = fg(s);
    }
    long gs = 0;
    for (int i = 0; i < 4096; i++)
        gs += out[i] * (i % 5 + 1);
    printf("%ld %.3f %ld %ld %ld %ld %ld\n", h, g, k, m, e, f, gs);
    return 0;
}
