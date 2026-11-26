// f8:pack(ue8m0), the unsigned scale, mixes with no other type in an
// operator, f4 included: one needs a cast.
// xtc: error "'f8:pack(ue8m0)' is a scale and does not mix with 'f4' without a cast"
#import "Stdio.xc"

i32 main(void)
{
    f4 a = 1.5;
    f8:pack(ue8m0) s = 2.0;
    f32 r = a * s;
    Stdio.printf("%f\n", r);
    return 0;
}
