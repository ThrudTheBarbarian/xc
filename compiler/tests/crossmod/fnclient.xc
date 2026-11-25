// fnclient.xc — calls fnlib's f32/f64 functions with float and double values,
// knowing the library only from its interface. See float-names.sh.
#import "Stdio.xc"
#use <FnLib>

i32 main(void)
{
    double d = 1.25;
    float r = narrow(d);
    FScale* s = new FScale(1.5);
    float v = 3;
    double a = s.apply(v);
    f64 t = FScale.sum(a, r);
    Stdio.printf("narrow %f apply %f sum %f\n", r, a, t);
    return 0;
}
