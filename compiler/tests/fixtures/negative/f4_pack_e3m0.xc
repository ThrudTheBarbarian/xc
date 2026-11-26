// f4 has one pack, e2m1.
// xtc: error "f4 has no pack 'e3m0': its one pack is e2m1 (OCP MX FP4, no infinity or NaN, largest value 6); write 'f4'"
#import "Stdio.xc"

i32 main(void)
{
    f4:pack(e3m0) q = 1.0;
    Stdio.printf("%f\n", q);
    return 0;
}
