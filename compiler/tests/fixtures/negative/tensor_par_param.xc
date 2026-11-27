// A tensor parameter may share its storage with any tensor of its element type.
// xtc: error "writes the tensor 'out' and reads the tensor 'src' at a different row; they may share storage"
#import "Stdio.xc"
#import "Par.xc"
void smooth(tensor<f32, 1> out, tensor<f32, 1> src)
{
    par step
    {
        for (u64 i in 1..8)
            out[i] = src[i - 1] + src[i];
    }
}
i32 main(void)
{
    tensor<f32, 1> a = new tensor<f32, 1>(9);
    smooth(a, a);
    return 0;
}
