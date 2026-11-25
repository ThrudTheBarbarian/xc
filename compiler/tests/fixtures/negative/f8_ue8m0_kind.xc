// ue8m0 has fixed special values: 0xFF is NaN and there is no infinity.
// xtc: error "ue8m0 takes no special-value kind"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(ue8m0, finite) s = 1.0;
    Stdio.printf("%f\n", s);
    return 0;
}
