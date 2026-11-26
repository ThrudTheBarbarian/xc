// f8 does not convert to f4 implicitly: the conversion rounds, so it needs a
// cast.
// xtc: error "'f8' does not convert to 'f4' without a cast"
#import "Stdio.xc"

i32 main(void)
{
    f8 x = 1.25;
    f4 w = x;
    Stdio.printf("%f\n", w);
    return 0;
}
