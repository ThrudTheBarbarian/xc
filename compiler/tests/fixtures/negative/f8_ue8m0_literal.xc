// ue8m0 holds powers of two from 2^-127 up: no zero and no negative value.
// xtc: error "a literal out of range for 'f8:pack(ue8m0)': it holds only powers of two from 2^-127 to 2^127, no zero or negative value"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(ue8m0) s = 0;
    Stdio.printf("%f\n", s);
    return 0;
}
