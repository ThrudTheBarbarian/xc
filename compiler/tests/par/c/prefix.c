/* prefix: a running sum (each element needs the one before: stays serial)
   and a histogram (a scattered update: stays serial). */
#include <stdio.h>
#define N 100000
unsigned a[N], p[N], hist[64];
int main(void)
{
    for (int i = 0; i < N; i++)
        a[i] = (unsigned)(i * 40503u) >> 10;
    p[0] = a[0];
    for (int i = 1; i < N; i++)
        p[i] = p[i - 1] + a[i];
    for (int i = 0; i < N; i++)
        hist[a[i] & 63]++;
    unsigned h = 0;
    for (int i = 0; i < 64; i++)
        h = h * 31 + hist[i];
    printf("%u %u\n", p[N - 1], h);
    return 0;
}
