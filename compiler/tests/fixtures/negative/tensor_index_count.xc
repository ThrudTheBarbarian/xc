// A tensor takes one index for each dimension.
// xtc: error "'tensor<f32, 2>' takes 2 indices, one for each dimension, as in t[i, j]"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(2, 3);
    t[1] = 1.0;
    return 0;
}
