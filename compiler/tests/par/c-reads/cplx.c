// A struct with a _Complex double member, which clang types as a literal
// struct field (`%struct.P = type { { double, double }, i32 }`, as
// libstdc++'s std::complex and std::function's storage are), and a local
// _Complex accumulator (`alloca { double, double }`).
#include <complex.h>
#include <stdio.h>

struct P { double _Complex z; int k; };
static struct P ps[64];

int main(int argc, char** argv)
{
    for (int i = 0; i < 64; i++) {
        ps[i].z = (double)i + (double)(i * (argc + 2)) * I;
        ps[i].k = i % 5;
    }
    double _Complex s = 0;
    for (int i = 0; i < 64; i++)
        s += ps[i].z * ps[i].k;
    printf("%.1f %.1f %zu\n", creal(s), cimag(s), sizeof(struct P));
    return 0;
}
