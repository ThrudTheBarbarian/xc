// An f4[] does not step: two elements share each byte.
// xtc: error "an 'f4[]' cannot step: two elements share each byte; keep an index and write a[i]"
#import "Stdio.xc"

i32 main(void)
{
    f4[] h = new f4[4];
    f4[] p = h + 1;
    p[0] = 1.0;
    Stdio.printf("%f\n", h[1]);
    return 0;
}
