// e2m1 has no infinity or NaN, so f4 takes no other kind.
// xtc: error "f4 takes no special-value kind 'ieee': e2m1 has no infinity or NaN; write 'f4'"
#import "Stdio.xc"

i32 main(void)
{
    f4:pack(e2m1, ieee) q = 1.0;
    Stdio.printf("%f\n", q);
    return 0;
}
