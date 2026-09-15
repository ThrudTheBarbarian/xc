// class_inherit_virtual.xc — PR8 virtual-dispatch coverage.
//
//   T1  Animal@ pointing at a Dog dispatches into Dog.speak — the
//       base-pointer call resolves to the subclass body at runtime.
//   T2  Animal@ pointing at a Cat dispatches into Cat.speak — same
//       call site, different dynamic type.
//   T3  Animal@ pointing at a bare Animal dispatches into
//       Animal.speak — the root of the override group still works.
//   T4  Two-level chain: Animal@ pointing at a Puppy (Puppy : Dog :
//       Animal) dispatches into Dog.speak because Puppy inherits
//       without overriding — class-id maps to Dog's vtable slot.
//   T5  Subclass-typed receiver gets the override directly, same
//       outcome as the base-typed one (no "accidental" static
//       dispatch to Animal on a subclass-typed variable).
//   T6  super.speak() bypasses virtual dispatch (always direct) —
//       inside Dog.speak a `super.speak()` call reaches
//       Animal.speak, not Dog's own body.
//   T7  Non-overridden methods stay static. Animal.sniff is
//       inherited unchanged and doesn't contribute a vtable slot.

#import "Stdio.xc"

u8 superReached;

class Animal
{
    u8 legs;
    void init(void) { legs = 4; }
    void speak(void) { Stdio.printf("animal\n"); }
    void sniff(void) { Stdio.printf("sniff\n"); }
}

class Dog : Animal
{
    u8 tail;
    void speak(void)
    {
        Stdio.printf("woof\n");
    }
    void barkAndChain(void)
    {
        super.speak();          // T6: must hit Animal.speak
    }
}

class Cat : Animal
{
    void speak(void) { Stdio.printf("meow\n"); }
}

class Puppy : Dog
{
    u8 weeks;
    // no speak override — Puppy instances dispatch via the vtable
    // to Dog.speak (the nearest ancestor impl in the chain).
}

void main(void)
{
    superReached = 0;

    Animal* a = new Animal();
    Animal* d = new Dog();
    Animal* c = new Cat();
    Animal* p = new Puppy();

    // T1 — Dog via Animal@.
    d.speak();
    Stdio.printf("T1 PASS\n");

    // T2 — Cat via Animal@.
    c.speak();
    Stdio.printf("T2 PASS\n");

    // T3 — bare Animal via Animal@.
    a.speak();
    Stdio.printf("T3 PASS\n");

    // T4 — Puppy via Animal@ reaches Dog.speak (inherited).
    p.speak();
    Stdio.printf("T4 PASS\n");

    // T5 — Dog via Dog@ reaches Dog.speak directly.
    Dog* dd = new Dog();
    dd.speak();
    Stdio.printf("T5 PASS\n");

    // T6 — super.speak() inside Dog.barkAndChain reaches Animal.speak.
    dd.barkAndChain();
    Stdio.printf("T6 PASS\n");

    // T7 — sniff isn't overridden anywhere. Static dispatch to
    // Animal.sniff regardless of receiver type.
    d.sniff();
    Stdio.printf("T7 PASS\n");
}
