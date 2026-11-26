// A literal beyond f4's range is an error, though a conversion saturates:
// 7 rounds past the largest value, 6.
// xtc: error "a literal out of range for 'f4': its largest finite value is 6"
#import "Stdio.xc"

i32 main(void)
{
    f4 w = 7.0;
    Stdio.printf("%f\n", w);
    return 0;
}
