/* atax: y = A^T (A x), integers. */
#include <stdio.h>
#define M 400
#define N 500
int A[M][N], x[N], tmp[M], y[N];
int main(void)
{
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++)
            A[i][j] = (i + j) % 9 - 4;
    for (int j = 0; j < N; j++)
        x[j] = j % 13 - 6;
    for (int i = 0; i < M; i++) {
        int s = 0;
        for (int j = 0; j < N; j++)
            s += A[i][j] * x[j];
        tmp[i] = s;
    }
    for (int j = 0; j < N; j++) {
        int s = 0;
        for (int i = 0; i < M; i++)
            s += A[i][j] * tmp[i];
        y[j] = s;
    }
    long long t = 0;
    for (int j = 0; j < N; j++)
        t += (long long)y[j] * (j + 1);
    printf("%lld\n", t);
    return 0;
}
