// f16 and bf16 are different packs of one width: neither holds every value of
// the other, so they have no common type and mixing them needs a cast.
// xtc: error "'f16' and 'bf16' have no common type"
#import "Stdio.xc"

i32 main(void)
{
    f16 a = 1.5;
    bf16 b = 2.5;
    f32 c = a + b;
    Stdio.printf("%f\n", c);
    return 0;
}
