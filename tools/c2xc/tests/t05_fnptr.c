#include <stdio.h>
typedef int (*binop)(int, int);
static int add(int a, int b)
    {
    return a + b;
    }
static int mul(int a, int b)
    {
    return a * b;
    }
struct cmd
    {
    const char* name;
    binop fn;
    };
static struct cmd table[] = {{"add", add}, {"mul", mul}};
static int apply(binop f, int a, int b)
    {
    return f(a, b);
    }
int main(void)
    {
    int i;
    for (i = 0; i < 2; i++)
        printf("%s=%d ", table[i].name, table[i].fn(6, 7));
    binop f = i > 1 ? add : mul;
    printf("%d %d\n", apply(f, 2, 3), (*mul)(4, 5));
    return 0;
    }
