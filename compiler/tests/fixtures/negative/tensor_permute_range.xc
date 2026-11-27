// permute's dimensions are those of the tensor.
// xtc: error "permute's dimension 3 is not one of 'tensor<f32, 3>', whose dimensions are 0 to 2"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3, 4);
    tensor<f32, 3> p = t.permute(0, 3, 1);
    return (i32)p.count;
}
