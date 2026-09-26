// logical_not_float.xc — bug 23. `!f` on a float/double is `f == 0.0`. The
// lowering used to reject it (reference) or emit an integer compare on a float
// register (port: assembler `cmp s8, #0`). Now both lower it to FCmp OEQ.
#import "Stdio.xc"

i32 classify(double hf, float lev)
{
    if ((hf != 0) && (lev != 0)) return (i32)1;
    else if ((!hf) && (!lev))    return (i32)2;   // !float on both
    return (i32)0;
}

i32 main(void)
{
    double d = 0.0; double e = 3.5; float f = 0.0; float g = -2.0;
    Stdio.printf("%d %d %d %d\n", !d, !e, !f, !g);      // 1 0 1 0
    Stdio.printf("c %d %d %d\n", classify(1.5, 2.0), classify(0.0, 0.0), classify(1.5, 0.0));  // 1 2 0
    return (i32)0;
}
