/* redstart: reductions whose accumulators start from a value other than
   the identity (a device must not start every thread from it). */
#include <stdio.h>
#define N 100000
volatile unsigned start = 1000;
volatile int floor_ = 77;
unsigned a[N];
int main(void)
{
    for (int i = 0; i < N; i++)
        a[i] = (i * 2654435761u) >> 26;
    unsigned s = start;
    for (int i = 0; i < N; i++)
        s += a[i];
    int mx = floor_;
    for (int i = 0; i < N; i++)
        if ((int)a[i] > mx)
            mx = (int)a[i];
    unsigned p = 3;
    for (int i = 0; i < N; i++)
        p *= (a[i] | 1);
    printf("%u %d %u\n", s, mx, p);
    return 0;
}
