// A tensor index is an integer.
// xtc: error "a tensor index is an integer, not 'float'"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(2, 3);
    f32 x = 1.0;
    Stdio.printf("%f\n", t[x, 1]);
    return 0;
}
