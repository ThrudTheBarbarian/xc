// There is no pointer to f4: an f4 array is passed as f4[].
// xtc: error "an f4 element has no byte address, so there is no pointer to f4; pass an f4 array as 'f4[]', and keep an index for one element"
#import "Stdio.xc"

f32 first(f4* a)
{
    return a[0];
}

i32 main(void)
{
    f4 a[2];
    a[0] = 0.5;
    Stdio.printf("%f\n", first(a));
    return 0;
}
