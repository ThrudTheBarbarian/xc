#include <stdio.h>
int main(void)
    {
    unsigned char a = 200, b = 100;
    int c = a + b; /* C promotes: 300 */
    short s = 30000;
    int t = s + s; /* 60000 */
    unsigned int u = 3;
    int v = -1;
    printf("%d %d %d\n", c, t, u > v);
    long big = 100000L;
    long sq = big * big;
    printf("%ld %d %d\n", sq, -7 / 2, -7 % 3);
    int x = 7;
    double d = x / 2;
    double e = (double)x / 2;
    printf("%.1f %.1f %d\n", d, e, (int)(3.7 + 0.5));
    return (a + b) & 0xFF;
    }
