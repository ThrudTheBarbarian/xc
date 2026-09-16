#include <stdio.h>
/* Labels the state machine cannot take over. Each block below owns one label
   but also holds a goto aimed at a label further out, so the block is not a
   region one state number can cover and the conversion falls through to xc's
   own goto and labels. t11 covers the state machine; this covers the rest. */
static int mixed(int v)
    {
    int i, n = 0;
    for (i = 0; i < 4; i++)
        {
retry:
        n++;
        if (n == 2)
            goto retry;
        if (n > v)
            goto done;
        }
done:
    return n;
    }
/* dead code between a bare goto and the label it jumps to: the label stays,
   because the goto still reaches it */
static int deadlbl(void)
    {
    int i, n = 0;
    for (i = 0; i < 3; i++)
        {
        if (i == 2)
            goto out;
        goto here;
        n = 99;
here:
        n++;
        }
out:
    return n;
    }
/* a label carrying an empty statement, at the end of its block */
static int emptylbl(void)
    {
    int i, n = 0;
    for (i = 0; i < 3; i++)
        {
        if (i == 1)
            goto out;
        if (n == 7)
            goto spin;
        n++;
spin: ;
        }
out:
    return n;
    }
/* a label inside a switch, and a jump out of one */
static int swmix(int v)
    {
    int n = 0;
    switch (v)
        {
        case 1:
again:
            n++;
            if (n < 3)
                goto again;
            goto out;
        case 2:
            n = 50;
            break;
        default:
            n = 7;
        }
    return n;
out:
    return 100 + n;
    }
int main(void)
    {
    printf("%d %d %d\n", mixed(3), deadlbl(), emptylbl());
    printf("%d %d %d\n", swmix(1), swmix(2), swmix(9));
    return 0;
    }
