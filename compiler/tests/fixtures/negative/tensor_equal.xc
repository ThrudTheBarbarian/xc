// Tensors have no ==: views may share a storage or hold equal elements.
// xtc: error "'tensor<f32, 1>' has no '==': compare the elements, or the shapes and the data() pointers"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 1> a = new tensor<f32, 1>(3);
    tensor<f32, 1> b = a;
    if (a == b)
        Stdio.printf("same\n");
    return 0;
}
