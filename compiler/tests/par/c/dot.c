/* dot: a float dot product and a max, values exact in float. */
#include <stdio.h>
#define N (1 << 20)
float x[N], y[N];
int main(void)
{
    for (int i = 0; i < N; i++) {
        x[i] = (float)(i % 8) * 0.5f;
        y[i] = (float)(i % 3);
    }
    float d = 0.0f;
    for (int i = 0; i < N; i++)
        d += x[i] * y[i];
    float mx = 0.0f;
    for (int i = 0; i < N; i++)
        if (x[i] + y[i] > mx)
            mx = x[i] + y[i];
    printf("%.1f %.1f\n", d, mx);
    return 0;
}
