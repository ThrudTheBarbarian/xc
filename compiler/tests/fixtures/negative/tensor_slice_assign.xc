// A slice is a view: assign to its elements.
// xtc: error "a slice of 'tensor<f32, 2>' is a view, not an element"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 2> t = new tensor<f32, 2>(4, 4);
    t[0..2, ..] = 1.0;
    return 0;
}
