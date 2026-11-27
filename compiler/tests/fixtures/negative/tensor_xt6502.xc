// xt6502 returns at most 16 bytes by value, and a tensor value is wider.
// xtc: target xt6502
// xtc: error "tensors are not available on xt6502, whose functions return at most 16 bytes by value"
#import "Stdio.xc"
i32 main(void)
{
    tensor<u8, 1> t = new tensor<u8, 1>(4);
    t[0] = 1;
    return 0;
}
