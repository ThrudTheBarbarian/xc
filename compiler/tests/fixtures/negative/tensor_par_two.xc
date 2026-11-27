// Two tensor values may share one storage: a par block writes through one.
// xtc: error "writes the tensors 't' and 'u', which may share one storage"
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(8, 4);
    tensor<f32, 2> u = t;
    par fill
    {
        for (u64 i in 0..8)
            for (u64 j in 0..4)
            {
                t[i, j] = 1.0;
                u[i, j] = 2.0;
            }
    }
    return 0;
}
