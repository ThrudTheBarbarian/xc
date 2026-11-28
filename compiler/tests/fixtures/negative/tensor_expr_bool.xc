// A comparison gives a tensor of bool; writing it into float elements needs
// a cast, as a bool into a float does.
// xtc: error "'tensor<f32, 1>' does not hold every value of 'tensor<bool, 1>': cast it, as in (tensor<f32, 1>)x"
i32 main(void)
{
    tensor<f32, 1> a = new tensor<f32, 1>(4);
    tensor<f32, 1> m = new tensor<f32, 1>(4);
    m[..] = a > 1.0;
    return 0;
}
