/* gemm: C = A * B, 128x128 integers. */
#include <stdio.h>
#define N 128
int A[N][N], B[N][N], C[N][N];
int main(void)
{
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            A[i][j] = (i * j) % 7 - 3;
            B[i][j] = (i + 2 * j) % 5 - 2;
        }
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            int s = 0;
            for (int k = 0; k < N; k++)
                s += A[i][k] * B[k][j];
            C[i][j] = s;
        }
    long long t = 0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            t += C[i][j] * (long long)(i + j);
    printf("%lld\n", t);
    return 0;
}
