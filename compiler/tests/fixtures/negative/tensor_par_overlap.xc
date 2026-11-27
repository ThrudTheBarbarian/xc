// Two slices of one tensor that overlap cannot both be written by a block.
// xtc: error "writes the tensors 'top' and 'bottom', which may share one storage"
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(8, 4);
    u64 h = 4;
    tensor<f32, 2> top = t[0..h + 1, ..];
    tensor<f32, 2> bottom = t[h.., ..];
    par halves
    {
        for (u64 i in 0..4)
            for (u64 j in 0..4)
            {
                top[i, j] = 1.0;
                bottom[i, j] = 2.0;
            }
    }
    return 0;
}
