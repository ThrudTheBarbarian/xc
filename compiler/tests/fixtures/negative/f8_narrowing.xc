// f32 does not convert to f8 implicitly: the conversion rounds, so it needs a
// cast.
// xtc: error "'float' does not convert to 'f8' without a cast"
#import "Stdio.xc"

i32 main(void)
{
    f32 x = 1.25;
    f8 w = x;
    Stdio.printf("%f\n", w);
    return 0;
}
