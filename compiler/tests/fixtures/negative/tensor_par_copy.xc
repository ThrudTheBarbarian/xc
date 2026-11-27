// A copy of a tensor shares its storage: a par block that writes one and reads
// the other at another row would race.
// xtc: error "writes the tensor 't' and reads the tensor 'u' at a different row; they may share storage: read 'u' at the same row, or copy it first"
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(9, 4);
    tensor<f32, 2> u = t;
    par shift
    {
        for (u64 i in 0..8)
            for (u64 j in 0..4)
                t[i, j] = u[i + 1, j];
    }
    return 0;
}
