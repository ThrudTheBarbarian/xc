// addr_of_ivar.xc — `&` on a class ivar.
//
// Taking the address of a class field was not lowered at all: `&caret` fell out of the
// bottom of the &-identifier chain ("not pinned"), and `&self.ted` was rejected because
// that path only handled STRUCT bases. Both ABANDONED the function — which emitted no
// code for it — while the build SUCCEEDED with only a note. So `o.ob_spec =
// (pointer)&ted` carried garbage and objc_edit got a bad pointer, silently.
//
// Both forms now lower, and a lowering abandon is now a hard ERROR (an unimplemented
// feature costs an hour; one that silently emits nothing costs trust in every other
// answer the compiler gives). See private:docs/Design/no-silent-degradation.md.
//
// The pointers are read back THROUGH, not just tested non-null — a non-null pointer to
// the wrong place is exactly the failure being guarded against.

#import "Stdio.xc"

struct TE { i16 a; i16 b; }

class W
{
    TE  ted;
    i16 caret;

    void run(void)
    {
        pointer p1 = (pointer)&ted;         // implicit self, STRUCT ivar
        pointer p2 = (pointer)&caret;       // implicit self, SCALAR ivar
        pointer p3 = (pointer)&self.ted;    // explicit self

        ted.a  = (i16)5;
        ted.b  = (i16)6;
        caret  = (i16)9;

        TE*  tp = (TE*)p1;
        i16* cp = (i16*)p2;
        TE*  sp = (TE*)p3;

        Stdio.printf("same=%d\n", (i16)(p1 == p3));            // &ted IS &self.ted
        Stdio.printf("read=%d %d %d\n", tp.a, tp.b, cp[0]);    // 5 6 9, through the pointers

        sp.a = (i16)77;                                        // WRITE through it
        Stdio.printf("wrote=%d\n", ted.a);                     // 77 — it really is the field
    }
}

i16 main(void) { W* w = new W(); w.run(); return 0; }
