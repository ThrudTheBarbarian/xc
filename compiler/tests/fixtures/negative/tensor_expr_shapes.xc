// Operands whose shapes are known as the program compiles must broadcast:
// lined up from the last dimension, each pair of sizes equal, or one of
// them 1.
// xtc: error "tensor shapes 3 x 4 and 5 do not broadcast: dimension 1 has sizes 4 and 5; each must be the same, or 1"
i32 main(void)
{
    tensor<f32, 2> a = new tensor<f32, 2>(3, 4);
    tensor<f32, 1> b = new tensor<f32, 1>(5);
    tensor<f32, 2> c = a * 2.0 + b;
    return 0;
}
