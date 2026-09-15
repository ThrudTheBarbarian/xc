// PR1 smoke: `class X : Y` parses, sema wires parentClass, and a
// program that uses both classes without relying on any inheritance
// semantics (no shared ivar access, no super.init, no override)
// compiles and runs identically to the parentless shape. Exercises
// only the hierarchy plumbing — PR2 onwards adds ivar layout,
// method resolution, etc.
//
// Animal and Dog each own their own methods with distinct names, so
// nothing about this program depends on PR2+ behaviour.

#import "Stdio.xc"

class Animal
{
    u8 legs;
    void describe(void) { Stdio.printf("animal legs=%d\n", legs); }
}

class Dog : Animal
{
    u8 tailWag;
    void bark(void) { Stdio.printf("woof tail=%d\n", tailWag); }
}

void main(void)
{
    Animal a;
    a.legs = 4;
    a.describe();

    Dog d;
    d.tailWag = 2;
    d.bark();

    Stdio.printf("T1 PASS\n");
}
