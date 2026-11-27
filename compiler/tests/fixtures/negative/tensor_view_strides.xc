// view() of a transposed tensor cannot merge its dimensions in place.
// xtc: error "view() cannot reshape this view of 'm' in place"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> m = new tensor<f32, 2>(3, 4);
    tensor<f32, 1> v = m.transpose().view(12);
    return (i32)v.count;
}
