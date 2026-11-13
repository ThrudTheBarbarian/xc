// A bound read through a pointer each pass (i < *n) beside stores to a[i]:
// a block where the stores cannot reach *n, the loop as written where they
// do (n inside a: the loop overwrites its own bound).
#include <stdio.h>
#include <stdlib.h>
__attribute__((noinline)) static void zap(unsigned char* a, const long* n)
    {
    for (long i = 0; i < *n; i++)
        a[i] = (unsigned char)(i * 3 + 1);
    }
__attribute__((noinline)) static long sum(unsigned char* a, const long* n)
    {
    long s = 0;
    for (long i = 0; i < *n; i++) { a[i] = (unsigned char)i; s += a[i]; }
    return s;
    }
int main(void)
    {
    unsigned char* buf = calloc(1 << 20, 1);
    long* n = malloc(sizeof(long)); *n = 1 << 20;
    zap(buf, n);
    long t = 0; for (long i = 0; i < (1 << 20); i++) t += buf[i];
    /* n inside the array: the loop overwrites its own bound */
    unsigned char* big = calloc(4096, 1);
    long* inner = (long*)(big + 1024); *inner = 3000;
    zap(big, inner);
    long t2 = 0; for (int i = 0; i < 4096; i++) t2 += big[i];
    long* n2 = malloc(sizeof(long)); *n2 = 100000;
    printf("%ld %ld %ld %ld\n", t, t2, *inner, sum(buf, n2));
    return 0;
    }
