//xtc-flags: target=arm64
// static_init_hoist_order.xc — an initialiser must not be RELOCATED earlier.
//
// private:docs/bugs/059. XTIROptStaticInitGuard hoists a class's guard to the function
// entry so it dominates the in-body guards, which the fold then removes. The
// domination argument is sound; the side effect was not. It moved WHEN the
// initialiser runs — from first use to function entry — so an `init` that reads
// state the function sets up in between silently saw the earlier value.
//
// This is a WRONG-ANSWER test, not a shape test: at -O2 before the fix it
// printed 0. -O0 and -O1 were correct, which is what made it so easy to miss.
//
// The fix keeps the optimisation where it is safe (an init that touches only
// its own static block still hoists) and declines it here, because `init` reads
// a global that `main` assigns.

#import "Stdio.xc"

u32 gSetUp;

class C
{
    static u32 seen;
    static void init(void) { seen = gSetUp; }
    static u32 get(void)   { return seen; }
}

i32 main(void)
{
    gSetUp = (u32)42;                 // set BEFORE the first use of C
    Stdio.printf("C.get() = %ld\n", C.get());
    return 0;
}
