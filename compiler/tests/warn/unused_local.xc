//xtc-warn: never used
// A local nothing reads. `_scratch` must NOT be reported — the underscore is
// how an author says the omission is deliberate, and a check without that
// escape hatch makes correct code noisy.
#import "Stdio.xc"
i32 main(void)
    {
    i32 used = (i32)1;
    i32 spare = (i32)2;    // never used
    i32 _scratch = (i32)3; // deliberate: must stay silent
    Stdio.printf("%ld\n", used);
    return 0;
    }
