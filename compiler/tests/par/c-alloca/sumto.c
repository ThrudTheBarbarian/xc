// A buffer whose size is known only at run time: __builtin_alloca(n) is
// `alloca i8, i64 %n` in clang's IR. xcc cannot give it a fixed slot, so
// sumto is clang's; a fixed slot of one word was overwritten by the loop.
#include <alloca.h>
#include <stdio.h>

static long sumto(int n)
{
    int* a = alloca((unsigned long)n * sizeof(int));
    for (int i = 0; i < n; i++)
        a[i] = i * 3;
    long s = 0;
    for (int i = 0; i < n; i++)
        s += a[i];
    return s;
}

int main(int argc, char** argv)
{
    (void)argv;
    printf("%ld\n", sumto(argc * 1000));
    return 0;
}
