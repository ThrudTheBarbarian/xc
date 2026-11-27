// Small vectors inside a function, one value a lane: loads and stores of
// <4 x float> and <2 x float>, lane reads and writes, elementwise arithmetic
// and negation, a shuffle, and a vector carried around a loop (a phi). No
// vector crosses a call (that is one register in the ABI, and clang's).
#include <stdio.h>

typedef float v4 __attribute__((vector_size(16)));
typedef float v2 __attribute__((vector_size(8)));
typedef int i4 __attribute__((vector_size(16)));

static float data[64];
static float out[64];
static int ints[16];

int main(int argc, char** argv)
{
    for (int i = 0; i < 64; i++)
        data[i] = (float)((i * 7 + argc) % 13) * 0.25f;
    for (int i = 0; i < 16; i++)
        ints[i] = i * argc - 5;
    v4 acc = {0, 0, 0, 0};
    for (int i = 0; i < 64; i += 4) {
        v4 x;
        __builtin_memcpy(&x, &data[i], sizeof x);
        acc = acc + x * (v4){1.0f, 2.0f, 0.5f, -1.0f};
        v4 y = -x;
        y[2] = (float)i;
        v4 z = __builtin_shufflevector(x, y, 3, 2, 5, 0);
        __builtin_memcpy(&out[i], &z, sizeof z);
    }
    v2 p = {1.5f, -2.5f};
    for (int i = 0; i < 10; i++)
        p = p * (v2){0.5f, 1.25f} + (v2){data[i], data[i + 1]};
    i4 q;
    __builtin_memcpy(&q, ints, sizeof q);
    q = (q << 2) ^ (i4){1, 2, 3, 4};
    float s = 0;
    for (int i = 0; i < 64; i++)
        s += out[i] * (float)(i % 3);
    printf("%.3f %.3f %.3f %.3f %.3f %.4f %.4f %d %d %d %d\n", acc[0], acc[1], acc[2], acc[3], s, p[0], p[1], q[0], q[1], q[2], q[3]);
    return 0;
}
