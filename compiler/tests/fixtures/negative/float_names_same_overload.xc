// `f32` and `float` are one type, so these two functions have the same
// signature: the second is a redefinition of the first, not an overload.
// xtc: error "Redefinition of 'scale' with same parameter types"
#import "Stdio.xc"

f32 scale(f32 v) { return v * 2; }
float scale(float v) { return v * 3; }

i32 main(void)
{
    Stdio.printf("%f\n", scale(1.5));
    return 0;
}
