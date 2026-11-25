// f32 takes only its own pack, e8m23.
// xtc: error "f32 has no pack 'e5m10': it takes only its own, e8m23"
#import "Stdio.xc"

i32 main(void)
{
    f32:pack(e5m10) x = 1.0;
    Stdio.printf("%f\n", x);
    return 0;
}
