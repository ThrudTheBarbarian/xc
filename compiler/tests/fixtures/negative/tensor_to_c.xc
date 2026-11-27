// C has no tensor type: pass t.data() instead.
// xtc: error "C has no tensor type, so 'sum' cannot take 't' as 'tensor<f32, 1>': pass t.data() and the shape"
#import "Stdio.xc"
extern f32 sum(tensor<f32, 1> t);
i32 main(void)
{
    tensor<f32, 1> a = new tensor<f32, 1>(3);
    Stdio.printf("%f\n", sum(a));
    return 0;
}
