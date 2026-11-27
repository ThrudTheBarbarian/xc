// A tensor has rank 1 to 8.
// xtc: error "a tensor's rank is an integer from 1 to 8, not '0'"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 0> t;
    return 0;
}
