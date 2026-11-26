// fp4.xc — xc's f4 arrays with C, which sees one as bytes, two elements to
// each, element 0 in the low nibble, and an f4 as the uint8_t holding its
// pattern: clang's C writes and reads elements, calls Fp4.xc's conversions,
// and calls an `extern` xc function taking an f4 array (a uint8_t* to C)
// through a pointer. See run.sh.
#import "Stdio.xc"
#import "Fp4.xc"
#import <fp4lib>

// C calls this through a pointer, with the array's bytes.
extern void xc_double(f4[] a, u32 n)
{
    for (u32 i = 0; i < n; i++)
        a[i] = a[i] * 2;
}

void main(void)
{
    f4 a[5];
    for (u32 i = 0; i < 5; i++)
        a[i] = (f4)((f32)i * 0.5);
    c_put(a, 3, $D);
    Stdio.printf("get %x %x %x\n", (u16)c_get(a, 1), (u16)c_get(a, 3), (u16)c_get(a, 4));
    Stdio.printf("sum %g\n", (f64)c_sum(a, 5, &fp4E2M1Value));
    c_scale(&xc_double, a, 5);
    Stdio.printf("doubled %g %g %g\n", a[1], a[3], a[4]);
    Stdio.printf("conv %x %x\n", (u16)c_conv(&fp4E2M1, 2.5), (u16)c_conv(&fp4E2M1, -100.0));
}
