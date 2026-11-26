// An f4 array element is half a byte: it has no address of its own.
// xtc: error "'&' cannot take the address of an f4 element: two elements share a byte; pass the array as 'f4[]' with the index"
#import "Stdio.xc"

void put(f4[] out, f4 v)
{
    out[0] = v;
}

i32 main(void)
{
    f4 a[4];
    put(&a[1], 1.5);
    Stdio.printf("%f\n", a[1]);
    return 0;
}
