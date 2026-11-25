// f32 does not convert to f16 implicitly: the conversion rounds, so it needs a
// cast.
// xtc: error "'float' does not convert to 'f16' without a cast"
#import "Stdio.xc"

i32 main(void)
{
    f32 x = 1.25;
    f16 h = x;
    Stdio.printf("%f\n", h);
    return 0;
}
