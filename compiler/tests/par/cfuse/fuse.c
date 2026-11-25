/* fuse.c — adjacent C loops --par-style lifts, fused into one block (#147):
 * a chain of elementwise loops and a sum fuses; a neighbour read, a sum the
 * next loop reads, two pointer arguments, and a call keep loops apart. */
#include <stdio.h>
#define N 300007
static float x[N], y[N], z[N], w[N];

static void viaPointers(float *p, float *q)
{
    for (int i = 0; i < N; i++) p[i] = (float)i * 0.5f;
    for (int i = 0; i < N; i++) q[i] = q[i] + 1.0f;
}

int main(void)
{
    for (int i = 0; i < N; i++) x[i] = (float)(i % 977) * 0.25f;
    for (int i = 0; i < N; i++) y[i] = x[i] * 2.0f + 1.0f;
    for (int i = 0; i < N; i++) z[i] = y[i] * y[i];
    double s = 0;
    for (int i = 0; i < N; i++) s += z[i];
    printf("chain %.1f\n", s);

    for (int i = 1; i < N; i++) w[i] = z[i] * 0.5f;
    for (int i = 1; i < N; i++) y[i] = w[i - 1] + 1.0f;
    double s2 = 0;
    for (int i = 0; i < N; i++) s2 += y[i];
    printf("neighbour %.1f\n", s2);

    viaPointers(w, z);
    double s3 = 0;
    for (int i = 0; i < N; i++) s3 += w[i] + z[i];
    printf("pointers %.1f\n", s3);
    return 0;
}
