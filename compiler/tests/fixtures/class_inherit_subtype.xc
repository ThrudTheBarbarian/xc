// class_inherit_subtype.xc — PR4 subtype compatibility. Exercises
// the three conversion sites:
//   T1  initialiser: Animal@ a = dog;
//   T2  parameter  : fn(Animal@) called with Dog@
//   T3  return     : Animal@ fn() { return dog; }
//   T4  plain assign (`=`) from Dog@ to Animal@.
//   T5  two-level chain: Puppy → Animal via Dog.
//
// Every touch of the parent-typed handle walks into the Animal
// portion of the shared PR2 layout, so the base method reads the
// same legs byte the subclass wrote. No overrides anywhere — the
// PR4 override guard stays quiet because resolution lands on a
// non-overridden method in every call.

#import "Stdio.xc"

class Animal
{
    u8 legs;
    void describe(void)
    {
        Stdio.printf("legs=%d\n", legs);
    }
}

class Dog : Animal
{
    u8 tailWag;
}

class Puppy : Dog
{
    u8 weeks;
}

void touch(Animal* a)
{
    a.describe();
}

Animal* makeOne(void)
{
    Dog* d = new Dog();
    d.legs = 4;
    return d;
}

void main(void)
{
    // T1: initialiser subtype.
    Dog* d = new Dog();
    d.legs = 3;
    Animal* a = d;
    a.describe();
    Stdio.printf("T1 PASS\n");

    // T2: parameter subtype.
    Dog* d2 = new Dog();
    d2.legs = 5;
    touch(d2);
    Stdio.printf("T2 PASS\n");

    // T3: return subtype.
    Animal* r = makeOne();
    r.describe();
    Stdio.printf("T3 PASS\n");

    // T4: plain assign (existing variable).
    Dog* d3 = new Dog();
    d3.legs = 6;
    a = d3;
    a.describe();
    Stdio.printf("T4 PASS\n");

    // T5: two-level chain. Puppy → Dog → Animal.
    Puppy* p = new Puppy();
    p.legs = 7;
    touch(p);
    Animal* a2 = p;
    a2.describe();
    Stdio.printf("T5 PASS\n");
}
