#include <stdio.h>
typedef int (*cb_t)(int);
static int twice(int x)
    {
    return 2 * x;
    }
static int thrice(int x)
    {
    return 3 * x;
    }
static void reg(cb_t f, int v)
    {
    printf("%d ", f(v));
    }
static void reg2(int (*f)(int), int v)
    {
    printf("%d ", (*f)(v));
    }
int main(void)
    {
    cb_t a = &twice, b = thrice;
    reg(&twice, 1);
    reg(thrice, 2);
    reg(a, 3);
    reg2(b, 4);
    reg2(&twice, 5);
    if (a == twice && b != a)
        printf("same\n");
    return 0;
    }
