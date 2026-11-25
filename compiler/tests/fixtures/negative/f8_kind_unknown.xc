// A pack's special values are ieee, finite or none.
// xtc: error "'maybe' is not a special-value kind: write ieee, finite or none"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(e3m4, maybe) w = 1.0;
    Stdio.printf("%f\n", w);
    return 0;
}
