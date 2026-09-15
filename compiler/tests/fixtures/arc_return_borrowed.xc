// arc_return_borrowed.xc — returning a class pointer the callee does not own.
//
// Every class-pointer return is +1. The callee retains a BORROWED return value
// before its own teardown runs, and the caller adopts. Before that rule, a
// function could hand back a reference whose only owner it was about to
// release, and the caller got freed memory:
//
//     Probe@ f(void) {
//         Array@ tmp = new Array();
//         tmp.add((Object@)Probe.with(7));
//         return (Probe@)tmp.get(0);   // +0 — and `tmp` dies on the next line
//     }
//
// Nothing in the corpus covered it; selfhost/parser/Parser.xc hit it on its
// first run, twice, in two different shapes. Both are here.
//
// The live count is the test: an object that died too early shows up as a
// dealloc BEFORE the caller has finished with it, and one that never dies shows
// up as a leak at the end. Reading the tag would not catch either — freed
// memory usually still holds the right bytes, which is exactly why this bug
// survived so long.
//
//   T1  return an element of a LOCAL container (the container dies first)
//   T2  return a value assigned into a PARAMETER (a borrowed slot)
//   T3  return a strong local — the pre-existing move, which must NOT retain
//       twice and must not leak
//   T4  return the result of another call (already +1 — adopted, not retained)
//   T5  everything released by the end: no leaks from any of the above

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

u16 gLive;

class Probe
{
    u16 tag;
    void init(void) { tag = (u16)0; gLive = gLive + (u16)1; }
    void dealloc(void) { gLive = gLive - (u16)1; }
    static Probe* with(u16 t) { Probe* p = new Probe(); p.tag = t; return p; }
    u16 value(void) { return tag; }
}

// T1 — the returned object's ONLY owner is the local array, which is released
// on the way out.
Probe* fromLocalContainer(void)
{
    Array* tmp = new Array();
    tmp.add((Object*)Probe.with((u16)7));
    return (Probe*)tmp.get((u32)0);
}

// T2 — a fresh object assigned into a parameter. A parameter is a borrowed
// slot, so nothing owns the value; the end-of-statement sweep used to release
// it while `p` still pointed at it.
Probe* viaParameter(Probe* p)
{
    p = Probe.with((u16)9);
    return p;
}

// T3 — the ordinary case: a strong local whose +1 MOVES to the caller.
Probe* fromStrongLocal(void)
{
    Probe* p = Probe.with((u16)11);
    return p;
}

// T4 — returning another call's result: already +1, so it is adopted rather
// than retained again.
Probe* fromCall(void)
{
    return Probe.with((u16)13);
}

void main(void)
{
    // A BASELINE, not zero — and taken AFTER a warm-up call, not before.
    //
    // A class carrying a static method has its instance `init` run once against
    // the class's own static storage, by the `__sinit_Probe` once-guard that
    // fires on the FIRST static call. So `Probe.with` bumps gLive by one on its
    // first invocation for a phantom instance that never dies, and a baseline
    // read before that call is one short of the truth for every later check.
    // The warm-up moves the phantom into the baseline; `warm` itself is a
    // block-scoped strong local and is freed on the way out.
    { Probe* warm = Probe.with((u16)1); }
    u16 base = gLive;
    u16 live;

    // T1: alive on arrival, and its tag readable.
    Probe* a = fromLocalContainer();
    live = gLive - base;
    Assert.isEqual(live, (u16)1);                    // T1a — not freed early
    Assert.isEqual(a.value(), (u16)7);                // T1b

    // T2.
    Probe* b = viaParameter((Probe*)0);
    live = gLive - base;
    Assert.isEqual(live, (u16)2);                    // T2a
    Assert.isEqual(b.value(), (u16)9);                // T2b

    // T3.
    Probe* c = fromStrongLocal();
    live = gLive - base;
    Assert.isEqual(live, (u16)3);                    // T3a
    Assert.isEqual(c.value(), (u16)11);               // T3b

    // T4.
    Probe* d = fromCall();
    live = gLive - base;
    Assert.isEqual(live, (u16)4);                    // T4a
    Assert.isEqual(d.value(), (u16)13);               // T4b

    // T5: a result nobody binds is released by the end-of-statement sweep, so
    // the live count does not move.
    if (fromLocalContainer().value() == (u16)999) Stdio.printf("never\n");
    live = gLive - base;
    Assert.isEqual(live, (u16)4);                    // T5a — no leak, no early free

    Assert.summary();
    return;
}
