// arc_static_factory_arg.xc — a +1 value from a STATIC factory, passed
// straight into a call, must be released.
//
//     a.add(Number.with((i32)42));
//
// is the most idiomatic line in the whole Foundation API, and it leaked the
// Number every single time. Not a small leak: a churn loop building 200k
// twelve-element Arrays reached 826 MB of RSS, and every object in every
// container was lost.
//
// The cause was a conservatism in the owned-temporary sweep. At the end of a
// full expression the lowering releases any +1 temp no strong binding adopted
// — but only if the expression created NO control flow, since a temp born
// inside a ternary arm may not be live at the join. A static call, though,
// emits a static-init guard, and the guard BRANCHES:
//
//     if (__sinit_C == 0) { __sinit_C = 1; C$init(&__sdata_C); }
//
// so the full-expression ends in the guard's join block rather than the block
// it started in. The sweep saw "control flow happened", assumed a ternary, and
// dropped every pending temp untracked. Which is why `a.add(new Q())`,
// `a.add(freeFunction())` and `a.add(obj.method())` were all correct — only
// the STATIC call, which is the form the containers are built on, leaked.
//
// The fix releases a temp when it was defined in the block we are now in
// (every path here ran its defining call), while still dropping temps born in
// some other block. So this fixture pins BOTH sides:
//
//   T1  static factory as a call argument      → released
//   T2  new-as-argument                        → still released (unchanged)
//   T3  free function as argument              → still released (unchanged)
//   T4  instance method as argument            → still released (unchanged)
//   T5  static factory bound to a local        → still released (unchanged)
//   T6  static factory in a TERNARY arm        → the conservative path; must
//                                                not double-release (a crash),
//                                                whatever it does about the leak
//
// The counters are the whole test: made must equal gone.

#import "Foundation.xc"
#import "Stdio.xc"

u16 gMade = (u16)0;
u16 gGone = (u16)0;

class Q : Object
{
    u16 v;
    void init(void)    { gMade = gMade + (u16)1; }
    void dealloc(void) { gGone = gGone + (u16)1; }

    static Q* smake(void) { return new Q(); }      // static factory: +1
}

class F
{
    u16 v;
    void init(void) { v = (u16)0; }
    Q* imake(void)  { return new Q(); }            // instance factory: +1
}

Q* fmake(void) { return new Q(); }                 // free-function factory: +1

// Report and reset. `made` counts init(), `gone` counts dealloc(); a leak
// shows up as gone < made.
//
// Note the +1 in `made` that the static-init guard itself contributes: the
// first static call on a class runs `C$init(&__sdata_C)` once, on the class's
// static-data block. That is by design (it is how Stdio sets up its state),
// it happens once per class per program, and the object lives in static
// storage — so it is never dealloc'd. The tests below therefore compare
// against the count they actually created.
void report(u8* what)
{
    Stdio.printf("%s made=%d gone=%d\n", what, gMade, gGone);
    gMade = (u16)0;
    gGone = (u16)0;
}

i16 main(void)
{
    // Run one static call up front so the static-init guard's one-off
    // C$init(&__sdata_Q) is already spent and does not perturb the counts.
    Q* warm = Q.smake();
    gMade = (u16)0;
    gGone = (u16)0;

    // T1: THE BUG. Static factory straight into a call argument.
    { Array* a = new Array(); for (u16 i=(u16)0;i<(u16)3;i++) a.add(Q.smake()); }
    report("T1 static-as-arg  ");

    // T2: new as an argument — was already correct, must stay correct.
    { Array* a = new Array(); for (u16 i=(u16)0;i<(u16)3;i++) a.add(new Q()); }
    report("T2 new-as-arg     ");

    // T3: free function as an argument.
    { Array* a = new Array(); for (u16 i=(u16)0;i<(u16)3;i++) a.add(fmake()); }
    report("T3 freefn-as-arg  ");

    // T4: instance method as an argument.
    {
        F* f = new F();
        Array* a = new Array();
        for (u16 i=(u16)0;i<(u16)3;i++) a.add(f.imake());
    }
    report("T4 method-as-arg  ");

    // T5: static factory through a named local — the slot adopts the +1.
    { Array* a = new Array(); for (u16 i=(u16)0;i<(u16)3;i++) { Q* q = Q.smake(); a.add(q); } }
    report("T5 static-to-local");

    // T6: static factory inside a ternary arm. The sweep deliberately will
    // not release a temp born in a branch it may not have taken. What must
    // NOT happen is a double release — that is a use-after-free, and it would
    // show up here as a crash or a bogus count, not as a leak.
    {
        Array* a = new Array();
        bool yes = true;
        for (u16 i=(u16)0;i<(u16)3;i++) a.add(yes ? Q.smake() : (Q*)0);
        Stdio.printf("T6 ternary-arm    count=%d\n", a.count());
    }

    return 0;
}
