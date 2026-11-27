// permute's dimensions are literals, so the permutation is checked as it compiles.
// xtc: error "permute takes its dimensions as integer literals"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(2, 3);
    u64 k = 1;
    tensor<f32, 2> p = t.permute(k, 0);
    return (i32)p.count;
}
