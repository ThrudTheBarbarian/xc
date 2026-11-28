// A slice on the left is written in place: the value broadcasts to the
// slice's shape, so it cannot have more dimensions than the slice.
// xtc: error "a value of rank 2 does not fit 'tensor<f32, 1>', of rank 1"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(4, 4);
    t[0, ..] = t * 2.0;
    return 0;
}
