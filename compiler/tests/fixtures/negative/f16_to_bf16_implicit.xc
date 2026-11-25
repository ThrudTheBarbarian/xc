// f16 does not convert to bf16 implicitly: bf16 has fewer mantissa bits.
// xtc: error "'f16' does not convert to 'bf16' without a cast"
#import "Stdio.xc"

i32 main(void)
{
    f16 a = 1.0009765625;
    bf16 b = a;
    Stdio.printf("%f\n", b);
    return 0;
}
