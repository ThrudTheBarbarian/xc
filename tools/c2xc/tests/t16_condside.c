/* side effects inside a ternary branch or a short-circuit right side run only
   when that branch is taken: an assertion macro such as (c ? (oops(), 1) : 0) */
#include <stdio.h>
static int oopses = 0;
static void oops(const char* m)
    {
    oopses++;
    printf("oops %s\n", m);
    }
#define CANT_HAPPEN(c) ((c) ? (oops(#c), 1) : 0)
static int f(void)
    {
    printf("f\n");
    return 1;
    }
static int g(void)
    {
    printf("g\n");
    return 2;
    }
int main(void)
    {
    int n = 0, type = 3;
    if (CANT_HAPPEN(type >= 54))
        printf("bad\n");
    else
        printf("ok\n");
    if (CANT_HAPPEN(type >= 2))
        printf("bad2\n");
    if (n && (n++ > 0))
        printf("never\n");
    if (!n || (n++ > 0))
        printf("short %d\n", n);
    int k = (type > 2) ? (n++, 10) : (n += 100, 20);
    type > 2 ? f() : g();
    printf("k=%d n=%d oopses=%d\n", k, n, oopses);
    return 0;
    }
