// Every float compare clang writes, ordered and unordered, over values
// with NaN among them: x != y is `fcmp une`, !(x < y) `fcmp uge` and so on,
// isunordered `fcmp uno`. Prints one digit a compare, float and double.
#include <math.h>
#include <stdio.h>

static float vf[5];
static double vd[5];

__attribute__((noinline)) static int cmpf(float x, float y)
{
    return (x == y) | (x != y) << 1 | (x < y) << 2 | (x <= y) << 3 | (x > y) << 4 | (x >= y) << 5
         | (!(x < y)) << 6 | (!(x <= y)) << 7 | (!(x > y)) << 8 | (!(x >= y)) << 9
         | isunordered(x, y) << 10 | (!isunordered(x, y)) << 11 | (!(x != y)) << 12;
}

__attribute__((noinline)) static int cmpd(double x, double y)
{
    return (x == y) | (x != y) << 1 | (x < y) << 2 | (x <= y) << 3 | (x > y) << 4 | (x >= y) << 5
         | (!(x < y)) << 6 | (!(x <= y)) << 7 | (!(x > y)) << 8 | (!(x >= y)) << 9
         | isunordered(x, y) << 10 | (!isunordered(x, y)) << 11 | (!(x != y)) << 12;
}

int main(int argc, char** argv)
{
    vf[0] = 1.0f; vf[1] = 2.0f; vf[2] = 2.0f; vf[3] = NAN; vf[4] = -0.0f * (float)argc;
    for (int i = 0; i < 5; i++)
        vd[i] = (double)vf[i];
    long h = 0;
    for (int a = 0; a < 5; a++)
        for (int b = 0; b < 5; b++) {
            int f = cmpf(vf[a], vf[b]);
            int d = cmpd(vd[a], vd[b]);
            // The sort comparator's shape: a select of two compares.
            int s = vf[a] != vf[b] ? vf[a] > vf[b] : a < b;
            printf("%d%d %04x %04x %d\n", a, b, f, d, s);
            h = h * 31 + f + d + s;
        }
    printf("%ld\n", h);
    return 0;
}
