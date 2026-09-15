/* continue inside do-while must still run the condition's side effect */
#include <stdio.h>
static int tab[6] = {1, -1, 2, -1, 3, -1};
static int next(int* p)
    {
    return ++*p;
    }
int main(void)
    {
    int j = 0, n = 6, sum = 0, spins = 0;
    do
        {
        spins++;
        if (tab[j] < 0)
            continue;
        sum += tab[j];
        } while (++j < n);
    int k = 0, seen = 0;
    do
        {
        if (k == 2)
            continue;
        seen = seen * 10 + k;
        } while (next(&k) < 5);
    int m = 0;
    do
        {
        if (m == 3)
            break;
        m++;
        } while (++m < 10);
    printf("%d %d %d %d\n", sum, spins, seen, m);
    return 0;
    }
