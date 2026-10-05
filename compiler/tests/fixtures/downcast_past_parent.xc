//xtc-flags: target=arm64
// downcast_past_parent.xc — a checked downcast that matches past the first
// parent. At -O3 loop rotation copies the vtable walk's test to the bottom of
// the loop, which makes the walk's last block a second way into the join; the
// join's phi had no incoming for it, so on x86-64 `(A*)` of a C (two parents
// up) came back null while `(B*)` (one up) and `(C*)` (exact) were fine.
#import "Stdio.xc"

class A : Object
    {
    i32 v;
    }
class B : A
    {
    i32 w;
    }
class C : B
    {
    i32 z;
    }
class D : C
    {
    i32 q;
    }

i32 hit(Object* o)
    {
    A* a = (A*)o;
    return a != (A*)0 ? (i32)1 : (i32)0;
    }

void main(void)
    {
    Object* o = (Object*)new D();
    A* a = (A*)o;
    B* b = (B*)o;
    C* c = (C*)o;
    D* d = (D*)o;
    Stdio.printf("a=%d b=%d c=%d d=%d\n", a != (A*)0 ? 1 : 0, b != (B*)0 ? 1 : 0,
                 c != (C*)0 ? 1 : 0, d != (D*)0 ? 1 : 0);
    a.v = 7;
    Stdio.printf("v=%d via=%d\n", ((A*)o).v, hit((Object*)new C()) + hit((Object*)new B()) + hit((Object*)new A()));
    }
