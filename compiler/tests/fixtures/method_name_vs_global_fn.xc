// method_name_vs_global_fn.xc — member scope beats the free-function set.
//
// A bare call inside a method means `self.<name>(…)` whenever the enclosing
// class (or an ancestor) declares that name. It did not: the free-function
// overload set was consulted first, so ANY global function captured every
// same-named method in the program (bug 040).
//
// The library made that expensive rather than merely surprising. It is written
// in the same language and obeys the same rule, so one global named `add` broke
// Array.xc and CharacterSet.xc — code the user never touched — and the errors
// pointed inside the standard library.
//
// Both failure shapes are covered here. `capture` is the silent one: the global
// FITS, so there was no diagnostic at all and the class's own method simply
// never ran (n stayed 0). `arity` is the loud one: the global does not fit, and
// the old code reported "'add' takes 2 arguments; 1 given" instead of calling
// the method that took exactly one.
#import "Stdio.xc"

// Two globals whose names collide with methods below. `add` also collides with
// Array.add / Set.add in the standard library.
void add(i32 v)          { Stdio.print("  WRONG: global add ran\n"); }
i32  combine(i32 a, i32 b) { return a * (i32)100 + b; }

class Bag
{
    i32 n;
    void init(void) { n = (i32)0; }

    // Same name as the global, same arity: the global FITS. Member scope must
    // still win.
    void add(i32 v) { n = n + v; }

    // Same name as the global, DIFFERENT arity: resolving against the global
    // used to be an arity error rather than a call to this.
    i32 combine(i32 a) { return a + n; }

    void twice(i32 v) { add(v); add(v); }
    i32  viaMember(i32 a) { return combine(a); }

    // A class that declares the name may still call a global that it does not
    // declare — `describe` is not a member here.
    void report(void) { Stdio.printf("  bag n=%ld\n", n); }
}

// An INHERITED method counts: `Tote` declares neither, and both bare calls in
// the parent's methods must still reach Bag's.
class Tote : Bag
{
    void init(void) { n = (i32)0; }
    void addThrice(i32 v) { add(v); add(v); add(v); }
}

// THE CARVE-OUT. A method calling its OWN name means the free function, not
// itself: that is how a wrapper reaches the C function it wraps, and
// `static double sqrt(double v) { return sqrt(v); }` in Math is exactly this
// shape. There is no qualified spelling for a free function, so without the
// carve-out that line becomes unbounded recursion.
//
// The test has to be the NAME rather than the method identity. `twice` has a
// SIBLING overload, so "is this candidate the method I am compiling?" still
// finds `twice(i16)` — not itself — and captures the call straight back into
// the class. That version hung.
double twice(double x) { return x * 2.0d; }

class Wrapper
{
    void init(void) { }
    static double twice(double v) { return twice(v); }        // → the free one
    static double twice(i16 v)    { return twice((double)v); }
}

// A class that does NOT declare the name still reaches the free function, so
// the fix must not swallow ordinary global calls made from class code.
class Caller
{
    void init(void) { }
    i32 useGlobal(i32 a, i32 b) { return combine(a, b); }
}

i32 main(void)
{
    Bag* b = new Bag();
    b.twice((i32)5);
    Stdio.printf("capture %ld (want 10)\n", b.n);

    Stdio.printf("arity %ld (want 17)\n", b.viaMember((i32)7));

    Tote* t = new Tote();
    t.addThrice((i32)4);
    Stdio.printf("inherited %ld (want 12)\n", t.n);

    Caller* c = new Caller();
    Stdio.printf("global still reachable %ld (want 302)\n",
                 c.useGlobal((i32)3, (i32)2));

    Stdio.printf("self-wrapper %lf %lf (want 8 and 16)\n",
                 Wrapper.twice(4.0d), Wrapper.twice((i16)8));

    // And from outside any class the global is exactly what it was.
    Stdio.printf("free call %ld (want 908)\n", combine((i32)9, (i32)8));
    b.report();
    return 0;
}
