/* nestred: sums carried through an inner loop (one block, the outer loop),
   and a running total stored as it goes (not a block). */
#include <stdio.h>
#define N 300
int a[N][N]; long long run[N * N];
volatile long long start = 5;
int main(void)
{
    for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) a[i][j] = (i * 3 + j) % 11 - 5;
    long long t = start;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) { t += a[i][j]; run[i * N + j] = t; }
    long long u = start, m = 1;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) { u += a[i][j] * j; m ^= a[i][j]; }
    printf("%lld %lld %lld %lld\n", t, run[N * N / 2], u, m);
    return 0;
}
