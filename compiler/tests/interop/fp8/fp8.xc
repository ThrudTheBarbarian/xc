// fp8.xc — xc's 8-bit floats with C, which sees each value as a uint8_t:
// clang's C calls Fp8.xc's explicit conversions and an `extern` xc function
// taking and returning an f8 through pointers, and returns a pattern xc reads
// as an f8. See run.sh.
#import "Stdio.xc"
#import "Fp8.xc"
#import <fp8lib>

// C calls this through a pointer; its f8 crosses as the uint8_t it is.
extern f8 xc_half(f8 x)
{
    return x / 2;
}

void main(void)
{
    Stdio.printf("conv %x %x\n", (u16)c_conv(&fp8E4M3Nan, 500.0), (u16)c_conv(&fp8E4M3, 500.0));
    Stdio.printf("e5m2 %x\n", (u16)c_conv(&fp8E5M2Sat, 1e6));
    Stdio.printf("twice %x\n", (u16)c_twice(&xc_half, $48));
    Stdio.printf("value %g\n", (f64)c_value(&fp8E4M3Value, $3C));
    u8 raw = c_bits();
    f8 two = *(f8*)&raw;
    Stdio.printf("bits %g\n", two);
}
