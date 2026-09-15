//xtc-flags: target=arm64
// A `+1` temporary produced in the RIGHT arm of a short-circuit used to be
// dropped without a release — deliberately, because a value born in a
// conditional arm may be live on only one path and releasing it at the join
// would be unbalanced. But a short-circuit arm's value is a Bool, so a class
// temp born there can never BE the result, and dropping it is a plain leak.
//
// A leak is not merely untidy here: the runtime's refcount is a u16 that WRAPS.
// Leak the same object 65,536 times and its count returns to 0, and the next
// release frees an object its owner still points at. This loop runs past that
// boundary; before the fix it segfaults on the read after the wrap, and the
// crash lands nowhere near its cause (private:docs/bugs/025 — found by the ported
// optimiser, whose `funcNamed` has exactly this shape over a 1,300-function
// module).
#import "Foundation.xc"
#import "Stdio.xc"
use Stdio;

class Holder
{
    String* _name;
    static Holder* named(String* n) { Holder* h = new Holder(); h._name = n; return h; }
    String* name(void) { return _name; }
}

i32 main(void)
{
    Holder* h = Holder.named(String.withCString("target"));
    String* want = String.withCString("nope");
    for (u32 i = (u32)0; i < (u32)70000; i = i + (u32)1) {
        if (h.name() != 0 && h.name().equals(want)) return (i32)2;
    }
    printf("survived: %s\n", h.name().cString());
    return (i32)0;
}
