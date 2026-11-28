// % takes integer elements, as it takes integers.
// xtc: error "'%' takes integer elements, not 'f32'"
i32 main(void)
{
    tensor<f32, 1> a = new tensor<f32, 1>(4);
    tensor<f32, 1> r = a % 2.0;
    return 0;
}
