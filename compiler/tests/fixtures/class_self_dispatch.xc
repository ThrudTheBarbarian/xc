// class_self_dispatch.xc — a bare `f()` inside a method body is `self.f()`
// and MUST dispatch on self's runtime class.
//
// Regression: the implicit-self call path resolved statically against the
// LEXICALLY ENCLOSING class, so a base class's template method called its own
// implementation and ignored the subclass override — while the explicit
// `self.f()` spelling dispatched correctly. Silent wrong answer, every target:
//
//     b.viaSelf() == 10     (A.viaSelf hard-called A.f)   ✗ was
//     b.viaSelf() == 420    (A.viaSelf dispatches to B.f) ✓ is
//
// This breaks the template-method pattern, which is the spine of any UI
// toolkit: a base `display()` calling `drawRect()`, a base `mouseDown()`
// calling `hitTest()` — every one of those would silently call the base.
//
// Note the fix costs nothing where dispatch isn't needed: sema only allocates
// a vtable slot to an override ROOT, so `solo()` below — which nothing
// overrides — still lowers to a direct call.
#import "Stdio.xc"

class A
{
    u16 f(void)       { return 1; }
    u16 viaSelf(void) { return f() * 10; }        // implicit self
    u16 viaThis(void) { return self.f() * 10; }   // explicit self
    u16 solo(void)    { return 7; }               // never overridden
    u16 viaSolo(void) { return solo() * 10; }     // stays a direct call
}

class B : A
{
    u16 f(void) { return 42; }
}

void main(void)
{
    B* b = new B();
    A* a = b;                       // same object through a base pointer

    // T1: direct calls resolve to the override.
    Stdio.printf("b.f=%d\n",  b.f());
    Stdio.printf("a.f=%d\n",  a.f());

    // T2: implicit self must reach B.f (was 10 — the bug).
    Stdio.printf("b.viaSelf=%d\n", b.viaSelf());

    // T3: explicit self — the spelling that always worked.
    Stdio.printf("b.viaThis=%d\n", b.viaThis());

    // T4: a never-overridden sibling still resolves (direct call).
    Stdio.printf("b.viaSolo=%d\n", b.viaSolo());
}
