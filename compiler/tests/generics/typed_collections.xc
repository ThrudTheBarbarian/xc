// typed_collections.xc — element types on collections (stage D, reference side).
//
// Under tests/, so the differentials compare both compilers on it. Getting it
// here took fixing bug 035 first: this program's shape (a `Dog : Animal`
// override alongside protocol-bearing library classes) made the two compilers
// disagree about vtable slot NUMBERING, which is an ABI.
#import "Stdio.xc"
#import "String.xc"
#import "Array.xc"
#import "Number.xc"

class Animal
    {
    i16 legs;
    void init(void)
        {
        legs = (i16)4;
        }
    } class Dog : Animal
    {
    void init(void)
        {
        legs = (i16)4;
        }
    }

    i32
    main(void)
    {
    // Reading yields the element type — no cast at the use site.
    Array<String>* names = new Array();
    names.add(String.withCString("hello"));
    String* s = names.get((u32)0);
    Stdio.printf("name=%s len=%d\n", s.cString(), (i16)s.byteLength());

    // A subclass goes into a superclass collection.
    Array<Animal>* pets = new Array();
    pets.add(new Dog());
    Animal* a = pets.get((u32)0);
    Stdio.printf("legs=%d\n", a.legs);

    // A protocol stands in for a type at declaration.
    Array<Comparable>* cmp = new Array();
    cmp.add(String.withCString("x"));
    // A PRIMITIVE element type. The value still travels boxed — a Number goes
    // in and `i32 v = …` unboxes on the way out — but conformance is judged by
    // the DECLARED type, so this collection refuses a float (see run.sh).
    Array<i32>* nums = new Array();
    nums.add((i32)7);
    nums.add((i32)9);
    i32 v = nums.get((u32)0);
    Stdio.printf("num=%d nums=%d\n", (i16)v, (i16)nums.count());

    Stdio.printf("count=%d %d %d\n", (i16)names.count(), (i16)pets.count(), (i16)cmp.count());
    return 0;
    }
