// bf16 does not convert to f16 implicitly: f16 has the smaller range.
// xtc: error "'bf16' does not convert to 'f16' without a cast"
#import "Stdio.xc"

f16 narrow(bf16 g)
{
    return g;
}

i32 main(void)
{
    Stdio.printf("%f\n", narrow(1.0));
    return 0;
}
