/* A program of two C files: twoalloc.c allocates the arrays (each 64 KB and
   more), this one runs the lifted loop over them, as a block. */
#include <stdio.h>
#include <stdlib.h>
float* make(int n, int k);

static void axpy(float* y, const float* x, const int* idx, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = x[idx[i]] * 2.0f + y[i];
    }

int main(void)
    {
    int n = 300000;
    float* x = make(n, 3);
    float* y = make(n, 7);
    int* idx = malloc(sizeof(int) * n);
    for (int i = 0; i < n; i++) idx[i] = (int)(((long)i * 7919) % n);
    axpy(y, x, idx, n);
    double s = 0;
    for (int i = 0; i < n; i++) s += y[i];
    printf("%.1f\n", s);
    free(x); free(y); free(idx);
    return 0;
    }
