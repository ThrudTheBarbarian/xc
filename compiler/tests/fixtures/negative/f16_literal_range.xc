// A literal beyond the largest finite f16, 65504, is an error.
// xtc: error "a literal out of range for 'f16': its largest finite value is 65504"
#import "Stdio.xc"

i32 main(void)
{
    f16 h = 70000.0;
    Stdio.printf("%f\n", h);
    return 0;
}
