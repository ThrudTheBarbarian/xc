// A literal beyond the largest finite E4M3, 448, is an error, though a
// conversion of a value that large saturates.
// xtc: error "a literal out of range for 'f8': its largest finite value is 448"
#import "Stdio.xc"

i32 main(void)
{
    f8 w = 500.0;
    Stdio.printf("%f\n", w);
    return 0;
}
