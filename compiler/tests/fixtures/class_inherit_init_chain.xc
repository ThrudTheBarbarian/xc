// class_inherit_init_chain.xc — PR5 init-chain coverage. Four shapes:
//   T1  subclass init explicitly calls `super.init()`  — parent-first
//       ordering, parent ivars valid when subclass runs.
//   T2  subclass init omits the super call — compiler auto-synthesises
//       `super.init()` at the top of the body (parent-first too).
//   T3  subclass init explicitly calls `super.init(args)` with args.
//   T4  two-level chain (Puppy -> Dog -> Animal): every ancestor's
//       init runs.

#import "Stdio.xc"

u8 animalInits;
u8 dogInits;
u8 puppyInits;

class Animal
{
    u8 legs;
    void init(void)
    {
        animalInits = animalInits + 1;
        legs = 4;
    }
}

class Dog : Animal
{
    u8 tailWag;
    void init(void)
    {
        super.init();                // T1 explicit no-arg
        dogInits = dogInits + 1;
        tailWag = 2;
    }
}

// Cat relies on the auto-synth path — body never mentions super.
class Cat : Animal
{
    u8 whiskers;
    void init(void)
    {
        whiskers = 6;
    }
}

// Vehicle's init takes args. Truck's init hand-threads the args.
class Vehicle
{
    u8 wheels;
    void init(u8 w) { wheels = w; }
}

class Truck : Vehicle
{
    u8 doors;
    void init(void)
    {
        super.init((u8)18);
        doors = 2;
    }
}

// Two-level chain — Puppy's auto-synth runs Dog.init (which itself
// runs Animal.init via an explicit super.init above).
class Puppy : Dog
{
    u8 weeks;
    void init(void)
    {
        puppyInits = puppyInits + 1;
        weeks = 3;
    }
}

void main(void)
{
    animalInits = 0;
    dogInits    = 0;
    puppyInits  = 0;

    Dog* d = new Dog();
    if (animalInits == 1 && dogInits == 1 && d.legs == 4 && d.tailWag == 2) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL a=%d d=%d legs=%d tail=%d\n",
                     animalInits, dogInits, d.legs, d.tailWag);
    }

    Cat* c = new Cat();
    if (animalInits == 2 && c.legs == 4 && c.whiskers == 6) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL a=%d legs=%d wh=%d\n",
                     animalInits, c.legs, c.whiskers);
    }

    Truck* t = new Truck();
    if (t.wheels == 18 && t.doors == 2) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL wh=%d doors=%d\n", t.wheels, t.doors);
    }

    Puppy* p = new Puppy();
    if (animalInits == 3 && dogInits == 2 && puppyInits == 1 &&
        p.legs == 4 && p.tailWag == 2 && p.weeks == 3) {
        Stdio.printf("T4 PASS\n");
    } else {
        Stdio.printf("T4 FAIL a=%d d=%d p=%d legs=%d tail=%d weeks=%d\n",
                     animalInits, dogInits, puppyInits,
                     p.legs, p.tailWag, p.weeks);
    }
}
