// ue8m0 has no sign bit and no negative values.
// xtc: error "'f8:pack(ue8m0)' has no sign: it cannot be negated"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(ue8m0) s = 4;
    f8:pack(ue8m0) t = -s;
    Stdio.printf("%f\n", t);
    return 0;
}
