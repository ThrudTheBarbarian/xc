// An f8 pack has 1 + X + Y = 8 bits: e4m4 has nine.
// xtc: error "f8 has no pack 'e4m4': a signed pack has 1 + X + Y = 8 bits"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(e4m4) w = 1.0;
    Stdio.printf("%f\n", w);
    return 0;
}
