// view() keeps the element count; shapes known as it compiles are checked then.
// xtc: error "view() of 'm', which holds 12 elements, as 10: the counts must be equal"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> m = new tensor<f32, 2>(3, 4);
    tensor<f32, 2> v = m.view(5, 2);
    return (i32)v.count;
}
