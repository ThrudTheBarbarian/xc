// vectorize_map.xc — elementwise i32 map loops the arm64 vectorizer
// rewrites to 128-bit NEON SIMD (4 lanes/iter): a[i]=b[i]+c[i] (VAdd)
// and d[i]=a[i]*3+7 (VMul + VAdd with splat constants). On xt6502 they
// stay scalar; each lane is independent, so SIMD is bit-for-bit the
// scalar result and all paths match the legacy oracle. Constant trip
// 128 (a multiple of the vector width). One arg per printf (a multi-arg
// printf trips a separate pre-existing varargs issue).

#import "Stdio.xc"

i32 a[128];
i32 b[128];
i32 c[128];
i32 d[128];

void main(void)
{
    for (u16 i = 0; i < 128; i = i + 1) { b[i] = (i32)(i + 1); c[i] = (i32)(2 * i); }
    for (u16 i = 0; i < 128; i = i + 1) a[i] = b[i] + c[i];      // VAdd
    for (u16 i = 0; i < 128; i = i + 1) d[i] = a[i] * 3 + 7;     // VMul + VAdd

    Stdio.printf("a0=%ld\n", a[0]);
    Stdio.printf("a127=%ld\n", a[127]);
    Stdio.printf("d0=%ld\n", d[0]);
    Stdio.printf("d63=%ld\n", d[63]);
    Stdio.printf("d127=%ld\n", d[127]);
}
