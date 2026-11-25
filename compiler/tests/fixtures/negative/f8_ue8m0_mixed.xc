// ue8m0 is a scale: it mixes with another type only through a cast.
// xtc: error "'f8:pack(ue8m0)' is a scale and does not mix with 'float' without a cast; convert it first, e.g. '(f32)s * x'"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(ue8m0) s = 4;
    f32 x = 1.25;
    f32 y = s * x;
    Stdio.printf("%f\n", y);
    return 0;
}
