// class_inherit_dealloc_chain.xc — PR6 dealloc-chain coverage.
//
//   T1  subclass dealloc explicitly calls super.dealloc() — child
//       tears down first, then parent runs.
//   T2  subclass dealloc doesn't mention super — compiler auto-
//       appends super.dealloc() at the END of the body (still
//       child-first).
//   T3  subclass has no dealloc of its own but parent does — the
//       auto-generated stub chains straight to the parent so the
//       refcount-to-zero path still runs the inherited cleanup.
//   T4  two-level chain: Puppy → Dog → Animal. Every ancestor
//       dealloc runs, exactly once per instance.
//   T5  ordering: the child's body runs BEFORE the parent's
//       (orderTag observes child -> parent sequence).

#import "Stdio.xc"

u8 animalDeallocs;
u8 dogDeallocs;
u8 catDeallocs;
u8 orderTag;       // 1 after child, 2 after parent — witnesses order

class Animal
{
    u8 legs;
    void init(void) { legs = 4; }
    void dealloc(void)
    {
        animalDeallocs = animalDeallocs + 1;
        if (orderTag == 1) { orderTag = 2; }
    }
}

class Dog : Animal
{
    u8 tailWag;
    void dealloc(void)
    {
        dogDeallocs = dogDeallocs + 1;
        if (orderTag == 0) { orderTag = 1; }
        super.dealloc();             // T1 explicit
    }
}

// Cat omits super.dealloc — compiler auto-appends it.
class Cat : Animal
{
    u8 whiskers;
    void dealloc(void)
    {
        catDeallocs = catDeallocs + 1;
    }
}

// Puppy declares no dealloc of its own. Auto-stub chains straight
// through Dog.dealloc (which itself explicitly calls super).
class Puppy : Dog
{
    u8 weeks;
}

void makeDog(void) { Dog* d = new Dog(); }
void makeCat(void) { Cat* c = new Cat(); }
void makePuppy(void) { Puppy* p = new Puppy(); }

void main(void)
{
    animalDeallocs = 0;
    dogDeallocs    = 0;
    catDeallocs    = 0;
    orderTag       = 0;

    makeDog();    // T1 + T5
    if (animalDeallocs == 1 && dogDeallocs == 1) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL a=%d d=%d\n", animalDeallocs, dogDeallocs);
    }
    if (orderTag == 2) {
        Stdio.printf("T5 PASS\n");
    } else {
        Stdio.printf("T5 FAIL order=%d\n", orderTag);
    }

    makeCat();    // T2
    if (animalDeallocs == 2 && catDeallocs == 1) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL a=%d c=%d\n", animalDeallocs, catDeallocs);
    }

    makePuppy();  // T3 — Puppy has no dealloc; auto-stub chains to Dog
    if (animalDeallocs == 3 && dogDeallocs == 2) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL a=%d d=%d\n", animalDeallocs, dogDeallocs);
    }

    makePuppy();  // T4 — two-level chain, each dealloc once more
    if (animalDeallocs == 4 && dogDeallocs == 3) {
        Stdio.printf("T4 PASS\n");
    } else {
        Stdio.printf("T4 FAIL a=%d d=%d\n", animalDeallocs, dogDeallocs);
    }
}
