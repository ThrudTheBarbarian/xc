// Calls its `^` UNGUARDED on purpose: this fixture pins the call mechanism
// itself, with a receiver that is alive throughout, so -Wunguarded-action
// fires here BY DESIGN. Not suppressed with a //xtc-flags: line, because
// the sweep honours only structured directives (target=/skip/na/expect=)
// and would silently ignore a -W flag — the warning goes to stderr and the
// sweep compares stdout, so it costs nothing.
// bound_method.xc — `&obj.method` yields a (recv, code) bound-method fat
// pointer, and `optional` protocol methods ride the same mechanism.
//
// The fat pointer is a compiler-synthesised 2-field struct, so it reuses the
// struct-by-value paths that already work on every backend — pass, return,
// store in an ivar, call through the code word. No new ABI.
//
// The code word is read from the receiver's VTABLE when the method has a slot
// (XTIROpVTblLoad), which is what makes all four of these true at once:
//
//   T1  target/action — say what you mean, no free-function + downcast-self
//       trampoline.
//   T2  the `^` binds the receiver's RUNTIME override, not the static type's
//       implementation (bound through a BASE pointer, reaches the subclass).
//   T3  an unimplemented `optional` protocol method has an empty vtable slot,
//       which every backend emits as a null word — so the `^` is null, and
//       `if (h)` IS respondsTo. No separate runtime query.
//   T4  a NULL receiver yields a null `^` rather than faulting. So ONE test
//       covers both "no delegate" and "delegate doesn't implement it".
//
// Truthiness of a `^` tests its CODE word, not recv — that's what lets T4
// coexist with widening a plain function to a `^` (where recv is legitimately
// null but the code word is real).
//
// See private:docs/Design/bound-methods.md.
#import "Stdio.xc"

typedef u16  act_t(void);
typedef bool pred_t(void);

// ── T1/T2: target/action + runtime override ──────────────────────────────
class Base            { u16 tag(void) { return (u16)1;  } }
class Derived : Base  { u16 tag(void) { return (u16)42; } }

// ── T3/T4: the delegate pattern ──────────────────────────────────────────
protocol WinDelegate
{
    void          winDidResize(void);         // required
    optional bool winShouldClose(void);       // may be absent
}

class Lazy <WinDelegate>                      // omits the optional method
{
    void winDidResize(void) { Stdio.printf("lazy resize\n"); }
}

class Full <WinDelegate>                      // implements it
{
    void winDidResize(void)   { Stdio.printf("full resize\n"); }
    bool winShouldClose(void) { return false; }
}

void probe(WinDelegate* d, u16 tag)
{
    // Null when d is null OR when d's class didn't implement it.
    pred_t^ h = &d.winShouldClose;
    if (h) { Stdio.printf("tag=%d responds close=%d\n", tag, (u16)h()); }
    else   { Stdio.printf("tag=%d does not respond\n", tag); }
}

void main(void)
{
    // T1: bind a method to its receiver and call through the pair.
    Derived* d = new Derived();
    act_t^ a = &d.tag;
    Stdio.printf("direct=%d\n", a());

    // T2: bind through a BASE pointer — must still reach Derived's override.
    Base* b = d;
    act_t^ v = &b.tag;
    Stdio.printf("virtual=%d\n", v());

    // T3: absent vs present optional method.
    probe(new Lazy(), (u16)1);
    probe(new Full(), (u16)2);

    // T4: null receiver — falsy, must not fault.
    probe((WinDelegate*)0, (u16)3);
}
