#include <stdio.h>
#include <stdarg.h>
struct n
    {
    int a;
    int money;
    short r;
    };
static struct n s = {1, 123456789, 0};
static void pr(char* fmt, ...)
    {
    char buf[128];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    printf("%s\n", buf);
    }
int main(void)
    {
    struct n* p = &s;
    double d = 2.5;
    int k = 7;
    pr("A $%.2f", d);
    pr("B %.2f r %d", d, k);
    pr("C %.2f r %d", d, p->r);
    pr("D $%.2f r %d", (double)p->money, p->r);
    pr("E %.2f r %d", (double)p->money, k);
    pr("F %.2f", (double)p->money);
    pr("G %d %.2f", k, d);
    return 0;
    }
