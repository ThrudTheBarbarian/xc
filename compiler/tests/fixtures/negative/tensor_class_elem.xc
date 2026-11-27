// A tensor holds scalars: no class elements.
// xtc: error "a tensor's elements are integers, bool, f64, f32, f16, bf16, f8, f4 or a pack of these, not 'Point'"
#import "Stdio.xc"
class Point { i32 x; }
i32 main(void)
{
    tensor<Point, 1> t;
    return 0;
}
