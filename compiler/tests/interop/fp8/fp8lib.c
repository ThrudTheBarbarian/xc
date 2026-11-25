/* fp8lib.c — C, built by clang, that works with xc's 8-bit floats. C has no
   8-bit float type: it holds each value as its bit pattern, a uint8_t, and
   calls xc's conversions (Fp8.xc) and an xc function taking an f8 through
   pointers. */
#include <stdint.h>

typedef uint8_t (*conv_t)(double);
typedef uint8_t (*half_t)(uint8_t);
typedef float (*value_t)(uint8_t);

uint8_t c_conv(conv_t f, double x) { return f(x); }
uint8_t c_twice(half_t f, uint8_t v) { return f(f(v)); }
float c_value(value_t f, uint8_t v) { return f(v) * 2.0f; }
/* E4M3's 2.0. */
uint8_t c_bits(void) { return 0x40; }
