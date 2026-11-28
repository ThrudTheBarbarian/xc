// Elements of two types mix only when one type holds every value of the
// other, as scalars do; f16 and bf16 need a cast.
// xtc: error "'tensor<f16, 1>' and 'tensor<bf16, 1>' have no common element type: neither holds every value of the other; cast one, as in (tensor<f32, 1>)x"
i32 main(void)
{
    tensor<f16, 1> h = new tensor<f16, 1>(4);
    tensor<bf16, 1> g = new tensor<bf16, 1>(4);
    tensor<f32, 1> s = (tensor<f32, 1>)h + g;
    tensor<f16, 1> t = h + g;
    return 0;
}
