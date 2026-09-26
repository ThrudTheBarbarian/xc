// overload_virtual_dispatch.xc — each overload of a virtual method dispatches
// through its own slot.
//
// The slot a class-typed call used was looked up by the method's NAME, so two
// overloads of one name shared whichever slot was recorded last: `a.f(1.5)`
// on a `B` ran B's `f(i32)` override with a garbage argument instead of A's
// `f(double)`. The same held for overloads that differ only in return type and
// for a call through the implicit self.

#import "Stdio.xc"

class A : Object
{
    void f(i32 x)
    {
        Stdio.printf("A.f(i32) %ld\n", x);
    }
    void f(double d)
    {
        Stdio.printf("A.f(double) %ld\n", (i32)(d * 10.0d));
    }
    void g(u8 x)
    {
        Stdio.printf("A.g(u8) %d\n", x);
    }
    void g(u8 x, u8 y)
    {
        Stdio.printf("A.g(u8,u8) %d %d\n", x, y);
    }
    // Implicit-self calls to each overload.
    void both()
    {
        f((i32)3);
        f(4.5d);
    }
}

class B : A
{
    void f(i32 x)
    {
        Stdio.printf("B.f(i32) %ld\n", x);
    }
    void g(u8 x, u8 y)
    {
        Stdio.printf("B.g(u8,u8) %d %d\n", x, y);
    }
}

class C : A
{
    void f(double d)
    {
        Stdio.printf("C.f(double) %ld\n", (i32)(d * 10.0d));
    }
}

// Overloads that differ only in their return type.
class N : Object
{
    i32 v()
    {
        return 1;
    }
    double v()
    {
        return 2.5d;
    }
}

class M : N
{
    i32 v()
    {
        return 10;
    }
}

// Overrides the double form only. Its parameters match the i32 form too, and
// that slot still belongs to N's body.
class P : N
{
    double v()
    {
        return 7.5d;
    }
}

void main(void)
{
    A* a = new B();
    a.f((i32)7);
    a.f(1.5d);
    a.g((u8)1);
    a.g((u8)2, (u8)3);
    a.both();

    A* c = new C();
    c.f((i32)8);
    c.f(2.5d);
    c.both();

    A* p = new A();
    p.f((i32)9);
    p.f(3.5d);

    N* n = new M();
    i32 iv = n.v();
    double dv = n.v();
    Stdio.printf("v %ld %ld\n", iv, (i32)(dv * 10.0d));
    N* n2 = new N();
    i32 iv2 = n2.v();
    double dv2 = n2.v();
    Stdio.printf("v %ld %ld\n", iv2, (i32)(dv2 * 10.0d));
    N* n3 = new P();
    i32 iv3 = n3.v();
    double dv3 = n3.v();
    Stdio.printf("v %ld %ld\n", iv3, (i32)(dv3 * 10.0d));
}
