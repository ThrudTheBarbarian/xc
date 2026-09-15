// cloak_heap_class.xc — regression for `:cloaked` heap-class instance
// methods on stack-in-bank-0 xe targets (canonical xe + xe-shadow).
//
// Before the cloaked-emit A/X-preserve fix, the frame-restore PLA
// chain at the end of a `:cloaked` heap-class method clobbered the
// scalar return value (held in A by xtc convention). Symptom: a
// method like `u16 get(void) : cloaked { return v; }` would return
// 0 regardless of v's actual value, because the frame restore's PLA
// pulled $8B's saved value back into A on its way out.
//
// The fix: emitFrameRestore now stashes A/X to `_arc_retval_lo` /
// `_arc_retval_hi` (static slots in main RAM, allocated by retain.asm
// for the existing ARC return-value stash) before the hw-stack pops,
// then reloads them after. xe-heap (stack in main RAM) still uses
// the cheaper PHA/PLA wrap; only stack-in-bank-0 layouts route
// through static slots.

#import "Stdio.xc"
#import "Assert.xc"

class Box {
    u16 v;
    u8  c;
    void put(u16 x) : cloaked   { v = x; return; }
    u16  get(void)  : cloaked   { return v; }
    void putc(u8 x) : cloaked   { c = x; return; }
    u8   getc(void) : cloaked   { return c; }
}

void main(void)
{
    Assert.reset();
    Box* b = new Box();
    b.put(42);
    Assert.isEqual(b.get(), 42);     // T1: u16 return survives frame restore
    b.putc(7);
    Assert.isEqual(b.getc(), 7);     // T2: u8 return survives frame restore
    Assert.isEqual(b.get(), 42);     // T3: putc didn't disturb v
    Assert.summary();
    return;
}
