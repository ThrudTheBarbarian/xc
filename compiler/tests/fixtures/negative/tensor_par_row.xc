// Each work item keeps to its own first index of the tensor it writes.
// xtc: error "writes the tensor 't' at a first index that is not k * i + c"
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(8, 4);
    par fill
    {
        for (u64 i in 0..8)
            for (u64 j in 0..4)
                t[0, j] = (f32)i;
    }
    return 0;
}
