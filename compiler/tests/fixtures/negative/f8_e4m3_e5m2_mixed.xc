// E4M3 and E5M2 are different packs of one width: neither holds every value
// of the other, so they have no common type and mixing them needs a cast.
// xtc: error "'f8' and 'f8:pack(e5m2)' have no common type: neither holds every value of the other; convert both, e.g. '(f32)a + (f32)b'"
#import "Stdio.xc"

i32 main(void)
{
    f8 a = 1.5;
    f8:pack(e5m2) b = 2.5;
    f32 c = a + b;
    Stdio.printf("%f\n", c);
    return 0;
}
