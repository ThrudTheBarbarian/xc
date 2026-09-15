// Calls its `^` UNGUARDED on purpose: this fixture pins the call mechanism
// itself, with a receiver that is alive throughout, so -Wunguarded-action
// fires here BY DESIGN. Not suppressed with a //xtc-flags: line, because
// the sweep honours only structured directives (target=/skip/na/expect=)
// and would silently ignore a -W flag — the warning goes to stderr and the
// sweep compares stdout, so it costs nothing.
// bound_method_local_weak.xc — gap F: a LOCAL `^` must not be a silent
// use-after-free, and neither must a `weak:` local pointer.
//
// THE TRUTH TEST LIED. A `^` doesn't retain its receiver and had no way to
// notice it dying — and the nasty part is that `if (action)` still tested TRUE
// afterwards, because the truth test is on CODE and only recv is dead. So the
// one guard a programmer reaches for was the guard that didn't work: the
// reproducer printed `ping from tag 0` out of freed memory rather than crashing.
//
// Fixing it for FIELDS (a `^` ivar auto-zeroes) was not enough: LOCALS were
// never registered in the weak side table at all. And that turned out to be
// bigger than bound methods — `weak:T@` on a LOCAL was silently a no-op too,
// for ordinary class pointers, independent of `^`. T2 pins that.
//
// A weak local must be PINNED for any of this to work: the side table zeroes the
// slot's MEMORY, which an SSA copy would never observe, so the guard would keep
// reading the stale pointer.
//
//   T1  a LOCAL `^` whose receiver dies goes falsy — the guard tells the truth,
//       and the action does NOT fire through freed memory.
//   T2  a LOCAL `weak:T@` whose target dies reads back null.
//
// See private:docs/Design/bound-methods.md §6.
#import "Stdio.xc"

typedef u16 act_t(void);

class C
{
    u16  tag;
    void init(void)     { tag = (u16)7; }
    u16  onClick(void)  { Stdio.printf("ping from tag %d\n", tag); return tag; }
    void dealloc(void)  { Stdio.printf("target-died\n"); }
}

void main(void)
{
    // T1: a local `^` outliving its receiver.
    act_t^ a;
    {
        C* c = new C();
        a = &c.onClick;
        Stdio.printf("alive=%d\n", a());
    }                                   // c dies here
    Stdio.printf("guard=%d\n", (u16)(a ? (u16)1 : (u16)0));
    if (a) { a(); }                     // must NOT fire
    Stdio.printf("no-fire\n");

    // T2: a local weak pointer outliving its target.
    weak:C* w;
    {
        C* c2 = new C();
        w = c2;
    }                                   // c2 dies here
    Stdio.printf("w-null=%d\n", (u16)(w == (C*)0 ? (u16)1 : (u16)0));
}
