// E4M3 does not convert to E5M2 implicitly: E5M2 has one mantissa bit fewer.
// xtc: error "'f8' does not convert to 'f8:pack(e5m2)' without a cast"
#import "Stdio.xc"

i32 main(void)
{
    f8 w = 1.125;
    f8:pack(e5m2) g = w;
    Stdio.printf("%f\n", g);
    return 0;
}
