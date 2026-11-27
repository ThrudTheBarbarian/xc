// new tensor<T, R>(...) takes R dimensions.
// xtc: error "new tensor<f32, 3> takes 3 dimensions, one for each index, as in new tensor<f32, 3>(d0, d1, d2)"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3);
    return 0;
}
