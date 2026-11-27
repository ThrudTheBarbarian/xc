// A slice has one position for each dimension.
// xtc: error "'tensor<f32, 3>' takes 3 positions in a slice, one for each dimension"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3, 4);
    tensor<f32, 2> s = t[1, 0..2];
    return (i32)s.count;
}
