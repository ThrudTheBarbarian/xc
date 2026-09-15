#include <stdio.h>
#include <stdarg.h>
static int sum(int n, ...)
    {
    va_list ap;
    int s = 0, i;
    va_start(ap, n);
    for (i = 0; i < n; i++)
        s += va_arg(ap, int);
    va_end(ap);
    return s;
    }
static void say(const char* fmt, ...)
    {
    char buf[64];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    printf("[%s]\n", buf);
    }
int main(void)
    {
    printf("%d\n", sum(4, 1, 2, 3, 4));
    say("%d-%s", 7, "x");
    return 0;
    }
