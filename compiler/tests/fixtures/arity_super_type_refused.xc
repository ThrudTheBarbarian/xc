//xtc-flags: expect=sema-error
// `super` has no single-candidate courtesy: an argument that does not convert
// to the parent's parameter is refused, not passed.
// Refused: No overload of 'super.m' matches (C*)
#import "Stdio.xc"

class A : Object { }
class C : Object { }

class B : Object
    {
    void m(A* a) { Stdio.printf("m\n"); }
    }

class K : B
    {
    void m(A* a) { super.m(new C()); }
    }

void main(void)
    {
    K* k = new K();
    k.m(new A());
    }
