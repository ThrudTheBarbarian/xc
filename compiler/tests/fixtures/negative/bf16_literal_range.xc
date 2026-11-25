// A literal beyond the largest finite bf16, about 3.39e38, is an error.
// xtc: error "a literal out of range for 'bf16': its largest finite value is 3.39e38"
#import "Stdio.xc"

i32 main(void)
{
    bf16 g = 3.4e38;
    Stdio.printf("%f\n", g);
    return 0;
}
