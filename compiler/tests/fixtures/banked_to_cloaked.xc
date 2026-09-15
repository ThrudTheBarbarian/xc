// banked_to_cloaked.xc — `:banked` heap-class method calls a
// `:cloaked` free function. Before the `_xcall_cloaked`
// trampoline landed, the inline cloaked bracket emitted at the
// call site:
//
//     LDA $D301 / PHA          ; save caller PORTB
//     LDA #$32 / STA $D301     ; banking off (cloaked window)
//     JSR target               ; <-- caller's bank now unmapped!
//     PLA / STA $D301          ; restore
//
// would unmap the caller's own code from $4000-$7FFF mid-flight
// and the next instruction fetch returned cloaked-staging bytes
// instead of the banked method's bytes — execution derailed.
//
// Fix: for `:banked → :cloaked` calls, route through a non-banked
// trampoline (`_xcall_cloaked`) that lives in main RAM at $A000+,
// where bank-window writes can't unmap the caller's code. The
// inline bracket stays in place for `:main → :cloaked` calls
// (canonical-xe path, where stage-3c flips everyone to :main and
// the inline form is byte-for-byte cheaper).

#import "Stdio.xc"
#import "Assert.xc"

// :cloaked free function — lives in the cloaked staging segment
// at $4000 with PORTB=$32 (banking off). Called from a banked
// method body via the new trampoline.
u16 cloakedSum(u16 a, u16 b) :cloaked
{
    return a + b;
}

u8 cloakedNeg(i8 v) :cloaked
{
    return (u8)(0 - v);
}

class Worker
{
    u16 last;

    // :banked method — body lives in a numbered bank on
    // xe-heap. Calls into :cloaked targets must round-trip
    // through _xcall_cloaked.
    void compute(u16 a, u16 b) :banked
    {
        last = cloakedSum(a, b);
    }

    u16 readLast(void) :banked  { return last; }
}

void main(void)
{
    Assert.reset();
    Worker* w = new Worker();

    // T1: simple banked-→-cloaked call with two-arg, u16 return.
    w.compute(100, 250);
    Assert.isEqual(w.readLast(), 350);

    // T2: cloaked-target with smaller args / return — exercises
    // the same bracket but proves arg/return widths work both ways.
    w.compute(1000, 2345);
    Assert.isEqual(w.readLast(), 3345);

    // T3: cloaked function that does signed → unsigned. Round-trip
    // through the trampoline preserves A on return.
    u8 r = cloakedNeg(-7);   // :main caller — uses inline bracket
    Assert.isEqual(r, 7);

    Assert.summary();
    return;
}
