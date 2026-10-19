/* particles: an array of structs, moved a step at a time. */
#include <stdio.h>
#define N 100000
struct P { int x, y, vx, vy; };
struct P ps[N];
int main(void)
{
    for (int i = 0; i < N; i++) {
        ps[i].x = i % 1000; ps[i].y = i / 1000;
        ps[i].vx = i % 7 - 3; ps[i].vy = i % 5 - 2;
    }
    for (int t = 0; t < 10; t++)
        for (int i = 0; i < N; i++) {
            ps[i].x += ps[i].vx;
            ps[i].y += ps[i].vy;
            if (ps[i].x < 0) ps[i].vx = -ps[i].vx;
        }
    long long s = 0;
    for (int i = 0; i < N; i++)
        s += ps[i].x * 3LL + ps[i].y + ps[i].vx;
    printf("%lld\n", s);
    return 0;
}
