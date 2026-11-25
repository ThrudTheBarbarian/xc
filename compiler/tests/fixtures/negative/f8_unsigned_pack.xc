// The one unsigned pack is ue8m0.
// xtc: error "f8 has no pack 'ue5m3': its one unsigned pack is ue8m0"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(ue5m3) s = 1.0;
    Stdio.printf("%f\n", s);
    return 0;
}
