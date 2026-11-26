// An f4 element cannot be an out-parameter: an out-parameter is a pointer,
// and the element has no byte address.
// xtc: error "'&' cannot take the address of an f4 element: two elements share a byte; pass the array as 'f4[]' with the index"
#import "Stdio.xc"

void halve(f4[] x)
{
    x[0] = (f4)((f32)x[0] / 2.0);
}

i32 main(void)
{
    f4[] h = new f4[3];
    h[2] = 3.0;
    halve(&h[2]);
    Stdio.printf("%f\n", h[2]);
    return 0;
}
