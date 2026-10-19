/* narrow: char and short conversions and arithmetic (C reads them as signed
   types; a zext of one clears its high bits). */
#include <stdio.h>
volatile int seed = 200;
unsigned char ub[4] = {250, 3, 128, 255};
signed char sb[4] = {-5, 100, -128, 7};
unsigned short us[3] = {65000, 7, 40000};
short ss[3] = {-30000, 12, 30000};
int main(void)
{
    int x = seed;
    signed char t = (signed char)(x + 100);       /* trunc then sext */
    unsigned char u = (unsigned char)(x + 100);   /* trunc then zext */
    short h = (short)(x * 300);
    unsigned short uh = (unsigned short)(x * 400);
    printf("%d %u %d %u\n", t, u, h, uh);
    unsigned s = 0; int q = 0;
    for (int i = 0; i < 4; i++) { s += ub[i] / 3 + (ub[i] >> 1) + ub[i] % 7; q += sb[i] / 3 + (sb[i] >> 1); }
    for (int i = 0; i < 3; i++) { s += us[i] / 5 + (us[i] >> 3); q += ss[i] / 7 + (ss[i] >> 2); }
    printf("%u %d\n", s, q);
    unsigned char m = ub[0]; m += ub[3];          /* wraps at 8 bits */
    unsigned short n = us[0]; n += us[2];
    printf("%u %u %d %d\n", m, n, ub[2] > sb[1], (signed char)ub[2] < sb[0]);
    return 0;
}
