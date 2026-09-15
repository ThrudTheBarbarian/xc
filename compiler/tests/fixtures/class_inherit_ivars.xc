// class_inherit_ivars.xc — cross-architecture inherited-ivar layout
// smoke. The point of the shifted layout is that Animal-typed
// accessors land on the same bytes the subclass writes through its
// Dog-typed accessors — read AND write through a base-typed pointer
// reach the inherited slots.
//
// Previously this used 6502 inline asm to read the class-id byte and
// the codegen-emitted `_ivar_<C>_<field>` / `_sizeof_<C>` equates,
// which made the fixture xt6502-only and tied to specific byte
// offsets. Those equates are test scaffolding, not part of the
// language; behaviour is what the language guarantees, so the
// rewritten tests exercise behaviour instead.

#import "Stdio.xc"

class Animal
{
    u8 legs;
    u16 age;
}

class Dog : Animal
{
    u8 trained;
    u16 badgeId;
}

void main(void)
{
    Dog* d = new Dog();
    d.legs    = (u8)4;
    d.age     = (u16)7;
    d.trained = (u8)1;
    d.badgeId = (u16)$ABCD;

    // T1-T4: direct ivar access on the subclass-typed pointer.
    if (d.legs    ==     4) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL %d\n", d.legs); }
    if (d.age     ==     7) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL %u\n", d.age); }
    if (d.trained ==     1) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL %d\n", d.trained); }
    if (d.badgeId == $ABCD) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL %x\n", d.badgeId); }

    // T5-T6: inherited fields read THROUGH a base-typed pointer hit the
    // same bytes the subclass wrote — the offset arithmetic agrees.
    Animal* a = d;
    if (a.legs == 4) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL %d\n", a.legs); }
    if (a.age  == 7) { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL %u\n", a.age); }

    // T7-T8: writes through the base-typed handle land in the SAME slots
    // the subclass reads — slots are shared, not copied.
    a.legs = (u8)9;
    if (d.legs == 9)  { Stdio.printf("T7 PASS\n"); } else { Stdio.printf("T7 FAIL %d\n", d.legs); }
    a.age = (u16)15;
    if (d.age  == 15) { Stdio.printf("T8 PASS\n"); } else { Stdio.printf("T8 FAIL %u\n", d.age); }
}
