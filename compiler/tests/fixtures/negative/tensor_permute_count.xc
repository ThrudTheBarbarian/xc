// permute takes one dimension for each of the tensor's.
// xtc: error "permute on 'tensor<f32, 3>' takes 3 dimensions, each of 0 to 2 once, as in t.permute(2, 1, 0)"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3, 4);
    tensor<f32, 3> p = t.permute(1, 0);
    return (i32)p.count;
}
