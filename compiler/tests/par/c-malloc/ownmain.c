/* A program with its own allocator (ownheap.c, compiled in or linked as a
   second object): its blocks come from its pool, and the gather over them
   gives the serial answer. */
#include <stdio.h>
#include <stdlib.h>
#ifdef OWN_HEAP_HERE
#include "ownheap.c"
#else
int pool_has(const void* p);
#endif

static void gather(float* y, const float* x, const int* idx, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = x[idx[i]] * 0.5f + 1.0f;
    }

int main(void)
    {
    int n = 200000;
    int* idx = malloc(sizeof(int) * n);
    float* x = calloc(n, sizeof(float));
    float* y = malloc(sizeof(float) * n);
    for (int i = 0; i < n; i++) { x[i] = (float)(i % 1000) * 0.5f; idx[i] = (i * 7919) % n; }
    gather(y, x, idx, n);
    y = realloc(y, sizeof(float) * n * 2);
    double s = 0;
    for (int i = 0; i < n; i++) s += y[i];
    printf("%.1f %d %d %d\n", s, pool_has(idx), pool_has(x), pool_has(y));
    free(idx); free(x); free(y);
    return 0;
    }
