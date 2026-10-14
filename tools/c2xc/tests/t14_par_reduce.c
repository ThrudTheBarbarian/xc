/* --par: the canonical counted reduction becomes a par :reduce block (the
   runner passes --par for a test named *_par_*). Exact integer sums, so the
   result is the same however the items are split; the second loop writes an
   array as well as reducing, which the prototype leaves alone (not a single
   scalar assignment), and the third reduces a non-unit stride, also left. */
#include <stdio.h>

static unsigned int xs[1 << 16];
static unsigned int ys[1 << 16];

int main(void)
{
    for (int i = 0; i < (1 << 16); i++)
        xs[i] = (unsigned int)i * 2654435761u;
    unsigned int total = 0;
    for (int i = 0; i < (1 << 16); i++)
        total += xs[i] * 3u + (unsigned int)i;
    unsigned int t2 = 0;
    for (int i = 0; i < (1 << 16); i++) {
        ys[i] = xs[i] + 1u;
        t2 += ys[i];
    }
    unsigned int t3 = 0;
    for (int i = 0; i < (1 << 16); i += 2)
        t3 += xs[i];
    printf("%u %u %u\n", total, t2, t3);
    return 0;
}
