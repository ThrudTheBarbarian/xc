// heap_refcount_wrap.xc — retain an object past 65,536 and back down again.
//
// The refcount was a u16 on every target, and a u16 WRAPS. Bugs 025 and 079
// were both the same accident: a count went round, a later release drove it to
// zero while references were still outstanding, and a LIVE object was freed.
// 65,536 is not a hypothetical ceiling — 079 hit it by retaining one String per
// lexer token in an ordinary compile.
//
// Nothing else in the fixture set goes near it, which is why the bug survived
// twice. This one does: 70,000 retains, then 70,000 releases, then USE the
// object. On a 16-bit count the releases reach zero after the wrap, the object
// is freed with a reference still held, and the final call reads freed memory.
// arm9, m68k and wasm32 keep a 16-bit count that saturates at 65,535 instead
// (bug 261), so there the object is leaked and the fixture passes too.
//
//xtc-na: xt6502 — a 70,000-slot Array does not fit in its heap;
//        arc_retain_saturate.xc covers the saturating count there
#import "Stdio.xc"

class Marker
{
    i32 tag;
    void init(void) { tag = (i32)0; }
    void set(i32 v) { tag = v; }
    i32  get(void)  { return tag; }
}

i32 main(void)
{
    Marker* m = new Marker();
    m.set((i32)1234);

    // Array.add retains; removeAll releases. 70,000 is past the u16 ceiling by
    // enough that a wrap cannot be mistaken for an off-by-one.
    Array* keep = new Array();
    for (u32 i = (u32)0; i < (u32)70000; i = i + (u32)1)
        keep.add((Object*)m);
    Stdio.printf("held %lu\n", keep.count());

    keep.removeAll();
    Stdio.printf("released\n");

    // If the count wrapped, `m` has already been freed — but reading freed
    // memory that nothing has reused gives the right answer back, which is
    // exactly why this class of bug hides. So CLAIM the block first: allocate
    // a run of same-sized objects, each stamped with a different value. One of
    // them lands on `m`'s storage if `m` was freed.
    Array* reclaim = new Array();
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) {
        Marker* other = new Marker();
        other.set((i32)7777);
        reclaim.add((Object*)other);
    }

    // `m` is still ours: we never gave up the original reference, so this must
    // read back what we stored. If the count wrapped it now reads 7777 — or
    // whatever the reclaiming object put there.
    Stdio.printf("tag %d\n", m.get());
    return 0;
}
