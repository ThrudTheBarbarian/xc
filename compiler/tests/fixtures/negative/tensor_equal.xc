// == on tensors compares their elements: the result is a tensor<bool, R>,
// not a condition.
// xtc: error "'tensor<bool, 1>' is not a condition: test its elements one at a time"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 1> a = new tensor<f32, 1>(3);
    tensor<f32, 1> b = a;
    if (a == b)
        Stdio.printf("same\n");
    return 0;
}
