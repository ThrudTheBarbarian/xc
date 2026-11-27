// A broadcast repeats elements, so a write through one is refused where it shows.
// xtc: error "a write through a broadcast view would change every element it repeats"
#import "Stdio.xc"
i32 main(void)
{
    tensor<f32, 1> row = new tensor<f32, 1>(4);
    tensor<f32, 2> b = row.broadcast(3, 4);
    b[1, 2] = 5.0;
    return 0;
}
