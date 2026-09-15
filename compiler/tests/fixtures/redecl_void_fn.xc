// Updated for the C-prototype merge rule (Task #1079): an IDENTICAL
// body-less redeclaration now MERGES, as repeated C prototypes do — this
// fixture used to expect a "Redefinition" error here, and its premise
// changed with the rule.
//
// What it still pins is what it was born for (XTC-BUGS #17): the overload
// mangler used to CRASH on a bare `pointer` parameter in a void-returning
// function (`-[XTType pointeeType]: unrecognized selector`). The bodied
// overload pair below drives that exact shape through the mangler — void
// return, bare-pointer param — and must compile and run, not fault.
#import "Stdio.xc"

void sink(pointer p);
void sink(pointer p);      // identical redeclaration — merges, C rule

u16 gGot;

void mix(pointer p) { gGot = gGot + (u16)1; }
void mix(u32 v)     { gGot = gGot + (u16)v; }

i32 main(void)
{
    u8 x;
    mix((pointer)&x);
    mix((u32)41);
    Stdio.printf("got=%d\n", gGot);
    return 0;
}
