// A struct copies its bytes, so it cannot hold a tensor value.
// xtc: error "a struct cannot hold a tensor<f32, 1>: a struct's copy counts no references to the tensor's storage; hold it in a class"
#import "Stdio.xc"
struct Row
{
    i32 n;
    tensor<f32, 1> t;
}
i32 main(void)
{
    Row r;
    r.n = 1;
    return 0;
}
