// Math.sqrt takes floating elements; an integer tensor needs a cast first.
// xtc: error "Math.sqrt takes tensors of f64, f32, f16, bf16, f8 or f4, not 'tensor<i32, 1>'"
#import "Math.xc"
i32 main(void)
{
    tensor<i32, 1> n = new tensor<i32, 1>(4);
    tensor<i32, 1> r = Math.sqrt(n);
    return 0;
}
