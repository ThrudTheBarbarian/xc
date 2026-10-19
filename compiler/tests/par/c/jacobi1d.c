/* jacobi-1d: a three-point stencil, swept back and forth, integers. */
#include <stdio.h>
#define N 100000
#define STEPS 20
unsigned a[N], b[N];
int main(void)
{
    for (int i = 0; i < N; i++)
        a[i] = (unsigned)(i * 2654435761u) >> 20;
    for (int t = 0; t < STEPS; t++) {
        for (int i = 1; i < N - 1; i++)
            b[i] = (a[i - 1] + a[i] + a[i + 1]) / 3;
        for (int i = 1; i < N - 1; i++)
            a[i] = (b[i - 1] + b[i] + b[i + 1]) / 3;
    }
    unsigned s = 0;
    for (int i = 0; i < N; i++)
        s = s * 31 + a[i];
    printf("%u\n", s);
    return 0;
}
