// An f4[] is indexed, not dereferenced.
// xtc: error "'*' cannot read through an 'f4[]': an f4 element has no byte address; index it, as in a[0]"
#import "Stdio.xc"

i32 main(void)
{
    f4[] h = new f4[3];
    h[0] = 1.0;
    f4 x = *h;
    Stdio.printf("%f\n", x);
    return 0;
}
