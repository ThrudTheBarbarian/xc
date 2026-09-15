// class_inherit_methods.xc — PR3 coverage for method resolution
// through the parent chain. Exercises four shapes:
//
//   T1  receiver-typed subclass call → resolves to an ancestor's
//       body; the emitted JSR must name the ancestor (`_cls_Animal_
//       describe`) even though the receiver is typed Dog.
//   T2  bare call inside a subclass method body → same chain walk
//       from the subclass's own scope.
//   T3  two-step chain (Puppy : Dog : Animal): a method declared
//       only on Animal must still reach from Puppy.
//   T4  the subclass's own method continues to resolve against
//       itself — parent-walk only kicks in when the leaf class
//       genuinely doesn't declare the name.

#import "Stdio.xc"

u8 animalDescribes;
u8 dogBarks;
u8 puppyYips;

class Animal
{
    u8 legs;
    void describe(void)
    {
        animalDescribes = animalDescribes + 1;
    }
}

class Dog : Animal
{
    u8 tailWag;
    void bark(void)
    {
        dogBarks = dogBarks + 1;
        // T2: bare call inside Dog — should resolve to Animal.describe
        // via the chain walk. Without PR3 this would fall through to
        // the free-function path and the call-graph would error out.
        describe();
    }
}

class Puppy : Dog
{
    u8 weeks;
    void yip(void)
    {
        puppyYips = puppyYips + 1;
    }
}

void main(void)
{
    animalDescribes = 0;
    dogBarks        = 0;
    puppyYips       = 0;

    // T1: call inherited method directly on the subclass.
    Dog d;
    d.describe();
    if (animalDescribes == 1) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL %d\n", animalDescribes); }

    // T2: subclass method makes a bare call that resolves to parent.
    d.bark();
    if (dogBarks == 1 && animalDescribes == 2) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL barks=%d describes=%d\n", dogBarks, animalDescribes); }

    // T3: two-step chain — Puppy : Dog : Animal.
    Puppy p;
    p.describe();
    if (animalDescribes == 3) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL %d\n", animalDescribes); }

    // T4: subclass's own method still wins.
    p.yip();
    if (puppyYips == 1) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL %d\n", puppyYips); }
}
