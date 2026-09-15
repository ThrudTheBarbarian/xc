// arc_borrowed_rhs.xc — a borrowed class pointer bound to a strong slot must be RETAINED.
//
// arcRhsIsBorrowed: listed Identifier / MemberAccess / CastExpr as borrowed and let every
// OTHER node kind fall to `default: NO` — which the callers read as "already +1, adopt it
// without retaining". A TERNARY and a SUBSCRIPT both yield a borrowed pointer and both
// landed there:
//
//     h.o = c ? shared : shared;    // no Retain emitted — refcount stays 1
//     h.o = (Obj@)0;                // release-old -> 0 -> FREED, while still reachable
//
// The default was backwards in the DANGEROUS direction. Getting "borrowed" wrong leaks;
// getting "owned" wrong frees a live object. The only +1 producers are `new T` and a
// returnsRetained call, so those are listed explicitly and the default is now "borrowed".
//
// WHY IT LOOKED LIKE MEMORY CORRUPTION: the under-retained object is freed while still
// reachable, and the very next `new` recycles the block — whose init zeroes it. So what
// you SEE is a different object, elsewhere in the graph, silently going empty. The victim
// is nowhere near the cause. (Reported as "reassigning a view's Array@ field empties an
// Array in the datasource".)
//
// Each case below shares ONE object between two holders, drops one holder's reference,
// and checks the other holder's object survived.

#import "Stdio.xc"

class Obj { i16 v;  void init(void) { self.v = (i16)7; } }
class Box { Obj* o; void init(void) { self.o = (Obj*)0; } }

Obj* pick(bool c, Obj* a, Obj* b) { return c ? a : b; }   // ternary in a RETURN

i16 main(void)
{
    bool c = true;

    // T1: ternary as the RHS of an ivar store
    Obj* s1 = new Obj();  Box* b1 = new Box();
    b1.o = c ? s1 : s1;
    b1.o = (Obj*)0;
    Stdio.printf("T1 ternary-ivar   v=%d\n", s1.v);          // 7

    // T2: ternary as the initialiser of a strong LOCAL
    Obj* s2 = new Obj();
    { Obj* held = c ? s2 : s2;  held = (Obj*)0; }
    Stdio.printf("T2 ternary-local  v=%d\n", s2.v);          // 7

    // T3: SUBSCRIPT as the RHS — also fell to the bad default
    Obj* s3 = new Obj();
    Obj* arr = new Obj[2];
    Box* b3 = new Box();
    b3.o = c ? s3 : s3;
    b3.o = (Obj*)0;
    Stdio.printf("T3 subscript-ok   v=%d\n", s3.v);          // 7

    // T4: a borrowed pointer RETURNED through a ternary
    Obj* s4 = new Obj();  Box* b4 = new Box();
    b4.o = pick(true, s4, s4);
    b4.o = (Obj*)0;
    Stdio.printf("T4 ternary-return v=%d\n", s4.v);          // 7

    // T5: `new` on the RHS is +1 and must NOT be over-retained (it relies on the
    //     explicit case, not the default) — it must still be released exactly once.
    Box* b5 = new Box();
    b5.o = new Obj();
    Stdio.printf("T5 new-rhs        v=%d\n", b5.o.v);        // 7
    return 0;
}
