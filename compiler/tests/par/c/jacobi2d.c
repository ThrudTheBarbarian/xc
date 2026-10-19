/* jacobi-2d: a five-point stencil on a 512x512 grid, integers. */
#include <stdio.h>
#define N 512
int a[N][N], b[N][N];
int main(void)
{
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            a[i][j] = (i * 37 + j * 11) & 1023;
    for (int t = 0; t < 4; t++) {
        for (int i = 1; i < N - 1; i++)
            for (int j = 1; j < N - 1; j++)
                b[i][j] = (a[i][j] + a[i - 1][j] + a[i + 1][j] + a[i][j - 1] + a[i][j + 1]) / 5;
        for (int i = 1; i < N - 1; i++)
            for (int j = 1; j < N - 1; j++)
                a[i][j] = b[i][j];
    }
    long long s = 0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            s += a[i][j] * (long long)(i ^ j);
    printf("%lld\n", s);
    return 0;
}
