// half16.xc — f16 and bf16 across the C calling convention: C functions
// built by clang called from xc (with more halves than registers), xc
// functions called back from C through pointers, a variadic C function and
// printf given halves (promoted to double). See run.sh.
#import "Stdio.xc"
#import <half16lib>

extern f16 h_add(f16 a, f16 b);
extern bf16 bf_id(bf16 x);
extern f16 h_neg(f16 x);
extern f16 h_many(f16 a, f16 b, f16 c, f16 d, f16 e, f16 f, f16 g, f16 h, f16 i, f16 j, i32 k, f16 l);
extern f64 h_mixed(f32 f, f16 h, f64 d, bf16 b, i32 i);
extern f16 h_callback(pointer f);
extern f32 bf_callback(pointer f, f32 v);
extern f64 h_vsum(i32 n, ...);

// C calls these through pointers, so they take and return their halves as C
// does: `extern`.
extern f16 c_many(f16 a, f16 b, f16 c, f16 d, f16 e, f16 f, f16 g, f16 h, f16 i, f16 j, i32 k, f16 l)
{
    return a - b + c - d + e - f + g - h + i * 3 - j * 2 + (f16)k + l / 4;
}

extern bf16 c_bf(bf16 x)
{
    return x * 3;
}

void main(void)
{
    f16 a = 1.5;
    f16 b = 0.0004887;
    Stdio.printf("h_add %g %g\n", h_add(a, b), h_add(65504, 32));
    Stdio.printf("bf_id %g\n", bf_id(3.140625));
    Stdio.printf("h_neg %g %g\n", h_neg(a), h_neg(0));
    Stdio.printf("h_many %g\n", h_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
    Stdio.printf("h_mixed %.9g\n", h_mixed(1.25, 2.5, 3.0, 4.0, 5));
    Stdio.printf("h_callback %g\n", h_callback(&c_many));
    Stdio.printf("bf_callback %.9g\n", bf_callback(&c_bf, 1.75));
    f16 t = 0.1;
    Stdio.printf("h_vsum %g\n", h_vsum(3, a, b, t));
    Stdio.printf("xc_many %g\n", c_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
}
