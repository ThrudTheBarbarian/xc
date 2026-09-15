// class_inherited_init.xc — a subclass that declares NO init still runs the inherited one.
//
// It ran NO initialiser AT ALL. `new Button()` looked for `Button$init`, there wasn't one,
// and it called nothing — so every field the parent's init would have set stayed null. It
// compiled clean and survived on luck until something dereferenced one of them.
//
// The subtle part: the chain ALREADY worked for a subclass that DOES declare an init (the
// auto-super-init). The hole was only the class that declares NONE — which is the common
// case for a plain subclass that adds a field and no behaviour, and is exactly what a UI
// toolkit's XGButton : XGControl looks like.
//
// Sema now synthesises an init for such a class whose body is nothing but that chain, so
// every consumer (heap `new`, the stack value-instance form, the interface serializer,
// reachability) sees an ordinary init.
//
// T1  subclass with no init            -> the parent's init runs
// T2  TWO levels with no init          -> still reaches the ancestor that has one
// T3  a chain of chains                -> D declares an init (auto-chaining to A), and E
//                                         declares none, so E must reach BOTH
// T4  a stack value instance           -> same hole, same fix
// T5  a subclass whose parent has NO init anywhere -> nothing to chain to; must not break

#import "Stdio.xc"

class A     { u16 a;  void init(void) { self.a = (u16)1; } }
class B : A { u16 b; }                                          // T1
class C : B { u16 c; }                                          // T2
class D : A { u16 d;  void init(void) { self.d = (u16)4; } }    // declares one -> auto-chains
class E : D { u16 e; }                                          // T3
class N     { u16 n; }                                          // no init anywhere
class M : N { u16 m; }                                          // T5

i16 main(void)
{
    B* b = new B();   Stdio.printf("T1 a=%d\n", b.a);              // 1
    C* c = new C();   Stdio.printf("T2 a=%d\n", c.a);              // 1
    E* e = new E();   Stdio.printf("T3 a=%d d=%d\n", e.a, e.d);    // 1 4
    B  s;             Stdio.printf("T4 a=%d\n", s.a);              // 1
    M* m = new M();   m.m = (u16)5;
                      Stdio.printf("T5 m=%d\n", m.m);              // 5 — did not break
    return 0;
}
