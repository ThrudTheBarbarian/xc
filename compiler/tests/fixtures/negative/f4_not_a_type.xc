// f4 is a width the language does not have yet.
// xtc: error "'f4' is not a type yet: the float types are f8, f16, bf16, f32 and f64"
#import "Stdio.xc"

i32 main(void)
{
    f4 q = 1.0;
    Stdio.printf("%f\n", q);
    return 0;
}
