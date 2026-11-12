/* A loop that stores y[i] and gathers x[idx[i]] (x never stored in the
   loop) runs as a guarded block: as a block when x and y lie in different
   heap blocks, serially when they share one. Case 1 has them apart; in case
   2 they are one malloc'd block and the gather reaches back past x's start
   into the y being written, which only a serial run gets right. */
#include <stdio.h>
#include <stdlib.h>

static void gather(float* y, const float* x, const int* idx, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = x[idx[i]] * 0.5f + 1.0f;
    }

int main(void)
    {
    int n = 100000;
    int* idx = malloc(sizeof(int) * n);
    /* Case 1: apart. */
    float* x = malloc(sizeof(float) * n);
    float* y = malloc(sizeof(float) * n);
    for (int i = 0; i < n; i++) { x[i] = (float)(i % 1000) * 0.5f; idx[i] = (i * 7919) % n; }
    gather(y, x, idx, n);
    double s1 = 0;
    for (int i = 0; i < n; i++) s1 += y[i];
    /* Case 2: one block. y is its first half, x its second; each gather
       reads the y written one step earlier (x[-n + i - 1] is y[i - 1]). */
    float* buf = malloc(sizeof(float) * 2 * n);
    for (int i = 0; i < 2 * n; i++) buf[i] = 1.0f;
    for (int i = 0; i < n; i++) idx[i] = i == 0 ? 0 : -n + i - 1;
    gather(buf, buf + n, idx, n);
    double s2 = 0;
    for (int i = 0; i < n; i += 997) s2 += buf[i];
    printf("%.1f %.1f\n", s1, s2);
    return 0;
    }
