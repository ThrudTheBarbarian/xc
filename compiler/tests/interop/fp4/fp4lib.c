/* fp4lib.c — C, built by clang, that works with xc's f4 arrays. C has no
   4-bit float type: it sees an f4 array as bytes, two elements to each with
   element 0 in the low nibble, and an f4 as its pattern in a uint8_t. It
   writes and reads elements by hand, and calls Fp4.xc's conversions and an
   xc function taking an f4 array, through pointers. */
#include <stdint.h>

typedef uint8_t (*conv_t)(double);
typedef float (*value_t)(uint8_t);
typedef void (*scale_t)(uint8_t*, uint32_t);

/* Element i of n set to the pattern v, the other nibble of its byte kept. */
void c_put(uint8_t* a, uint32_t i, uint8_t v)
{
    unsigned sh = (i & 1) * 4;
    a[i >> 1] = (uint8_t)((a[i >> 1] & ~(0xF << sh)) | ((v & 0xF) << sh));
}

uint8_t c_get(const uint8_t* a, uint32_t i)
{
    return (a[i >> 1] >> ((i & 1) * 4)) & 0xF;
}

float c_sum(const uint8_t* a, uint32_t n, value_t f)
{
    float s = 0;
    for (uint32_t i = 0; i < n; i++)
        s += f(c_get(a, i));
    return s;
}

uint8_t c_conv(conv_t f, double x) { return f(x); }
void c_scale(scale_t f, uint8_t* a, uint32_t n) { f(a, n); }
