#include <stdio.h>
#include <stdlib.h>
static int work(int n)
    {
    int *a = NULL, *b = NULL, i, s = 0;
    a = malloc(16);
    if (!a)
        goto fail;
    for (i = 0; i < n; i++)
        {
        if (i == 7)
            goto done;
        s += i;
        if (s > 100)
            goto fail;
        }
    b = malloc(16);
    if (n < 0)
        goto fail;
done:
    printf("done %d\n", s);
    free(a);
    free(b);
    return s;
fail:
    printf("fail\n");
    free(a);
    free(b);
    return -1;
    }
int main(void)
    {
    printf("%d %d %d\n", work(3), work(20), work(-2));
    return 0;
    }
