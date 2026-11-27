// An f4 element has no byte address: an f4 tensor has bytes(), not data().
// xtc: error "an f4 element has no byte address, so an f4 tensor has no data(); t.bytes() gives its bytes"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f4, 1> q = new tensor<f4, 1>(4);
    u8* p = q.data();
    return 0;
}
