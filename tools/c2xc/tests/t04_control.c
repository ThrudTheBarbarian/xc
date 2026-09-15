#include <stdio.h>
int classify(int c)
    {
    switch (c)
        {
    case -1:
        return 100;
    case 'a':
    case 'b':
        return 1;
    case 'c':
        printf("c "); /* fall through */
    case 'd':
        return 2;
    default:
        return 0;
        }
    }
int main(void)
    {
    int i, j, n = 0;
    do
        {
        n++;
        } while (n < 5);
    for (i = 0, j = 10; i < j; i++, j--)
        n += i;
    printf("%d %d %d\n", n, classify('c'), classify(-1));
    int k = 0;
    while (1)
        {
        if (++k > 3)
            break;
        if (k == 2)
            continue;
        printf("k%d ", k);
        }
    printf("\n%d %d %d\n", classify('a'), classify('z'), classify('d'));
    int m = 3;
    int r = m > 2 ? (m > 5 ? 9 : 4) : 0;
    int t = (m == 3) + (m == 4);
    printf("%d %d %d\n", r, t, !m);
    return 0;
    }
