// permute takes each dimension once.
// xtc: error "permute names dimension 1 twice"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3, 4);
    tensor<f32, 3> p = t.permute(1, 1, 0);
    return (i32)p.count;
}
