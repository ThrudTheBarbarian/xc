/* Blocks the outliner makes from C loops: the first writes out whole (its
   old contents need not reach a GPU), the second reads a[i] before writing
   it (they must). */
#include <stdio.h>
#include <stdlib.h>
#define N 1000000
static void fill(float *out, const float *in, int n) { for (int i = 0; i < n; i++) out[i] = in[i] * 2.0f; }
static void bump(float *a, int n) { for (int i = 0; i < n; i++) a[i] = a[i] + 1.0f; }
int main(void)
{
    float *in = malloc(N * sizeof(float)), *out = malloc(N * sizeof(float));
    for (int i = 0; i < N; i++) in[i] = (float)(i % 7);
    fill(out, in, N);
    bump(out, N);
    double s = 0;
    for (int i = 0; i < N; i++) s += out[i];
    printf("%.1f\n", s);
    return 0;
}
