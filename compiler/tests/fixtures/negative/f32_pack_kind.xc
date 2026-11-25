// f32 is IEEE binary32 and takes no other special values.
// xtc: error "f32 takes no special-value kind: its pack is IEEE's; write 'f32'"
#import "Stdio.xc"

i32 main(void)
{
    f32:pack(e8m23, finite) w = 1.0;
    Stdio.printf("%f\n", w);
    return 0;
}
