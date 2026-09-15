/* static locals: a ring of buffers returned to the caller, a first-use initialiser */
#include <stdio.h>
#include <string.h>
static char* prbuf(int v)
    {
    static int nbuf = -1;
    static char buf[4][16];
    if (++nbuf > 3)
        nbuf = 0;
    sprintf(buf[nbuf], "%d,%d", v, v * 2);
    return buf[nbuf];
    }
static int count(void)
    {
    static int n;
    static int tab[3] = {5, 6, 7};
    n++;
    return tab[n % 3] + n;
    }
int main(void)
    {
    char *a = prbuf(1), *b = prbuf(0), *c = prbuf(26);
    printf("%s %s %s %s %s\n", a, b, c, prbuf(3), prbuf(4));
    printf("%d %d %d\n", count(), count(), count());
    return 0;
    }
