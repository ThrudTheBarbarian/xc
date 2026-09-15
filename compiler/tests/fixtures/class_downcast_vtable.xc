// class_downcast_vtable.xc — runtime-checked downcasts where the source
// is a VTABLE class (conforms to a protocol, so every instance carries a
// vtable pointer in slot 0 instead of a bare class-id).
//
// This is the dominant real downcast shape: heterogeneous containers hand
// back an `Object@`/protocol reference and you recover the concrete type
// with `(T@ ?)`. The failable form must return null on a genuine type
// mismatch — the whole point of the `?`. A plain `(T@)` to a matching
// type (self or subtree) must succeed.
//
//   T1  correct failable downcast (Dog ← Animal, instance is Dog)  → non-null.
//   T2  WRONG-type failable downcast (Cat ← Animal, instance is Dog) → null.
//   T3  plain downcast that matches                                 → non-null.
//   T4  null operand, failable                                      → null.
//   T5  subtree membership: instance Puppy, downcast to Dog         → non-null.
//   T6  Puppy is not a Cat                                          → null.

#import "Stdio.xc"

protocol Named { u8 tag(void); }

class Animal <Named>
{
    u8 legs;
    void init(void) { legs = 4; }
    u8 tag(void) { return 0; }
}
class Dog : Animal   { void init(void) { legs = 4; } u8 tag(void) { return 1; } }
class Cat : Animal   { void init(void) { legs = 4; } u8 tag(void) { return 2; } }
class Puppy : Dog    { void init(void) { legs = 4; } u8 tag(void) { return 3; } }

void main(void)
{
    Animal* a = new Dog();              // dynamic type Dog (vtable)

    Dog* d = (Dog* ?)a;
    if (d != (Dog*)0)  Stdio.printf("T1 PASS\n"); else Stdio.printf("T1 FAIL\n");

    Cat* c = (Cat* ?)a;
    if (c == (Cat*)0)  Stdio.printf("T2 PASS\n"); else Stdio.printf("T2 FAIL\n");

    Dog* d2 = (Dog*)a;
    if (d2 != (Dog*)0) Stdio.printf("T3 PASS\n"); else Stdio.printf("T3 FAIL\n");

    Animal* none = (Animal*)0;
    Cat* c2 = (Cat* ?)none;
    if (c2 == (Cat*)0) Stdio.printf("T4 PASS\n"); else Stdio.printf("T4 FAIL\n");

    Animal* p = new Puppy();            // dynamic type Puppy
    Dog* pd = (Dog* ?)p;
    if (pd != (Dog*)0) Stdio.printf("T5 PASS\n"); else Stdio.printf("T5 FAIL\n");

    Cat* pc = (Cat* ?)p;
    if (pc == (Cat*)0) Stdio.printf("T6 PASS\n"); else Stdio.printf("T6 FAIL\n");

    return;
}
