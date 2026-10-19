/* conv2d: a 3x3 box blur of a 1024x1024 byte image. */
#include <stdio.h>
#define W 1024
unsigned char img[W * W], out[W * W];
int main(void)
{
    for (int i = 0; i < W * W; i++)
        img[i] = (unsigned char)((i * 7 + (i >> 10) * 13) & 255);
    for (int i = W; i < W * W - W; i++) {
        unsigned s = 0;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++)
                s += img[i + dy * W + dx];
        out[i] = (unsigned char)(s / 9);
    }
    unsigned h = 0;
    for (int i = 0; i < W * W; i++)
        h = h * 33 + out[i];
    printf("%u\n", h);
    return 0;
}
