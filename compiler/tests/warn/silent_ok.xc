// No expectation: this file must produce NO warning. A false positive is a
// bug in the analyser, and the only way to notice one is to assert silence
// somewhere ordinary.
#import "Stdio.xc"
i32 add(i32 a, i32 b)
    {
    return a + b;
    }
i32 main(void)
    {
    i32 t = (i32)0;
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        t = add(t, i);
    if (t > (i32)100)
        Stdio.printf("big\n");
    return t == (i32)6 ? (i32)0 : (i32)1;
    }
