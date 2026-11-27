// A slice's bounds are integers.
// xtc: error "a tensor index or slice bound is an integer, not 'float'"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(4, 4);
    tensor<f32, 2> s = t[0..1.5, ..];
    return (i32)s.count;
}
