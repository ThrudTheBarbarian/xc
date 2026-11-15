/* The gather of gather.c over arrays placed by the command line, for the
   heap-block test's view of malloc's blocks: `spans <n> <case>`.
   a: x and y are two malloc blocks, each from its start (a block when both
      are 64 KB or more, which the runtime allocates and records).
   m: x points 64 elements into its block, y is a block of its own (a block:
      the runtime sizes x to its block's end).
   p: as m, 4096 bytes in.
   i: y lies inside x's block, and the gather reads what it writes (serial).
   q: y lies 4096 bytes into x's block, x is its start (serial).
   n of 4000 makes blocks under 64 KB, the C library's, unknown (serial);
   100000 makes them the runtime's. */
#include <stdio.h>
#include <stdlib.h>

static void gather(float* y, const float* x, const int* idx, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = x[idx[i]] * 0.5f + 1.0f;
    }

int main(int argc, char** argv)
    {
    if (argc < 3)
        return 2;
    int n = atoi(argv[1]);
    char c = argv[2][0];
    int len = 2 * n + 1088;
    int* idx = malloc(sizeof(int) * n);
    float* xs = malloc(sizeof(float) * len);
    float* ys = malloc(sizeof(float) * n);
    for (int k = 0; k < len; k++) xs[k] = (float)(k % 1000) * 0.5f;
    for (int i = 0; i < n; i++) idx[i] = c == 'i' || c == 'q' ? (i * 7919) % (2 * n) : (i * 7919) % n;
    float* x = c == 'm' ? xs + 64 : c == 'p' ? xs + 1024 : xs;
    float* y = c == 'i' ? xs + n : c == 'q' ? xs + 1024 : ys;
    gather(y, x, idx, n);
    double s = 0;
    for (int i = 0; i < n; i++) s += y[i];
    printf("%.1f\n", s);
    return 0;
    }
