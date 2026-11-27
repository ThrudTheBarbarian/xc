// A tensor's dimensions are integers.
// xtc: error "a tensor's dimensions are integers, not 'float'"
#import "Stdio.xc"
i32 main(void)
{
    f32 n = 2.0;
    tensor<f32, 1> t = new tensor<f32, 1>(n);
    return 0;
}
