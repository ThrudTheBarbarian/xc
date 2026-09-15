// arc_ternary_owned.xc — a ternary whose ARM produces a +1 leaked it.
//
// private:docs/bugs/081, found by blewit growing in memory and root-caused there.
//
//   P* p = c ? new P() : new P();
//
// Both arms deliver +1. The arm temps were registered at the ARM's conditional
// depth, and the end-of-full-expression sweep only releases temps recorded at
// the CURRENT depth — rightly, since at the join it cannot know which arm ran.
// So nobody released them. On top of that the ownership classifier called the
// whole ternary BORROWED, so the binding retained as well: every evaluation
// leaked the object outright.
//
// Every existing ternary fixture in this corpus uses NAMED LOCALS in the arms
// (case E), which is the one shape that was always correct — which is why a
// 418-fixture sweep was green through it.
//
//   A  both arms `new`
//   B  one arm `new`, one an existing local — the MIXED case, where the
//      borrowed arm is retained in its own block so the join is +1 either way
//   C  both arms a call returning +1
//   D  the ternary as a call ARGUMENT rather than a binding: the phi has to be
//      registered at the OUTER depth or nobody sweeps it
//   E  both arms borrowed locals — must stay exactly as it was, because making
//      THIS owned is the older bug (`h.o = c ? shared : shared` freed a live
//      object; see arcRhsIsBorrowed's note)
#import "Stdio.xc"

class P
{
    static i32 made;
    static i32 gone;
    i32 tag;
    void init(void)    { tag = (i32)0; made = made + (i32)1; }
    void dealloc(void) { gone = gone + (i32)1; }
    i32 get(void)      { return tag; }
    static i32 live(void) { return made - gone; }
    static void zero(void) { made = (i32)0; gone = (i32)0; }
}

P* make(void) { return new P(); }
i32 takes(P* p) { return p.get(); }

i32 main(void)
{
    P.zero();
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        P* p = (i % (u16)2 == (u16)0) ? new P() : new P();
    }
    Stdio.printf("A %d\n", P.live());

    P.zero();
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        P* e = new P();
        P* p = (i % (u16)2 == (u16)0) ? new P() : e;
    }
    Stdio.printf("B %d\n", P.live());

    P.zero();
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        P* p = (i % (u16)2 == (u16)0) ? make() : make();
    }
    Stdio.printf("C %d\n", P.live());

    P.zero();
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        takes((i % (u16)2 == (u16)0) ? make() : make());
    }
    Stdio.printf("D %d\n", P.live());

    P.zero();
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        P* a = new P();
        P* b = new P();
        P* p = (i % (u16)2 == (u16)0) ? a : b;
    }
    Stdio.printf("E %d\n", P.live());
    return 0;
}
