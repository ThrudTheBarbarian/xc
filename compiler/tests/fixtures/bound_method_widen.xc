// bound_method_widen.xc — `@`→`^` widening, static-method refs, and IDENTITY.
//
// A control's action slot is a `^`. Three things must be able to fill it, and
// all three must be callable through the ONE uniform ABI `code(recv, args…)`:
//
//   T1  &obj.method          — a bound method (recv = the object)
//   T2  &freeFunction        — a plain function, widened
//   T3  &Class.staticMethod  — a static method (no receiver, so it IS just a
//                              function pointer, and widens the same way)
//
// A free function has no `self` parameter, so a widened `^` carries
//   recv = the function pointer,  code = __bm_tramp_<sig>
// where the trampoline drops the receiver and forwards. One trampoline per
// SIGNATURE (not per callee), which is what lets a RUNTIME function pointer
// widen too — the callee isn't known at the widening site.
//
//   T4  IDENTITY. A `^` is compared as a pair, so two `^`s naming the SAME
//       action must be equal — otherwise `removeAction(&f)` silently fails to
//       find what `addAction(&f)` stored. Same function → same recv; same
//       signature → same code. Held for both bound and widened forms.
//
// A `^` NEVER owns its recv: for a widened function that word is a CODE
// address, and retaining it would refcount .text.
//
// See private:docs/Design/bound-methods.md.
#import "Stdio.xc"

typedef u16 act_t(void);

u16 freeFn(void) { return (u16)42; }

class Controller
{
    u16  v;
    void init(void) { v = (u16)99; }
    u16  save(void) { return v; }
    static u16 onClick(void) { return (u16)7; }
}

class Button                       // a control that STORES an action
{
    act_t^ action;             // a stored ^ auto-zeroes — no keyword needed
    void   setAction(act_t^ a) { action = a; }
    u16    fire(void) { if (action) { return action(); } return (u16)0; }
}

void main(void)
{
    Controller* c = new Controller();
    Button* b = new Button();

    // T1: a bound method — the receiver rides in the `^`.
    b.setAction(&c.save);
    Stdio.printf("bound=%d\n", b.fire());

    // T2: a plain function, widened at the argument site.
    b.setAction(&freeFn);
    Stdio.printf("free=%d\n", b.fire());

    // T3: a static method — no receiver, widens like a free function.
    b.setAction(&Controller.onClick);
    Stdio.printf("static=%d\n", b.fire());

    // T4: identity, both forms.
    act_t^ x = &freeFn;
    act_t^ y = &freeFn;
    Stdio.printf("free-identity=%d\n", (u16)(x.code == y.code && x.recv == y.recv));

    act_t^ p = &c.save;
    act_t^ q = &c.save;
    Stdio.printf("bound-identity=%d\n", (u16)(p.code == q.code && p.recv == q.recv));

    // A widened `^` and a bound `^` must NOT collide.
    Stdio.printf("distinct=%d\n", (u16)(x.code != p.code));
}
