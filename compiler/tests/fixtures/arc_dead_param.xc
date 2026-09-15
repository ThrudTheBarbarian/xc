// arc_dead_param.xc — ARC 2e peephole: dead strong-pointer params.
//
// Callee-retains-params emits `JSR _obj_retain` on entry and a
// decref at scope exit for every strong class-pointer parameter.
// When the body never references the param, that retain/decref
// pair is pure overhead — the caller's +1 is already valid for
// the whole call under xtc's single-threaded invariants.
//
// The 2e peephole walks the body's AST at emit time and elides
// the pair for unused parameters. This fixture proves two things:
//   1. Correctness — a function with unused strong params still
//      returns normally and deallocCount stays balanced.
//   2. Observable elision — if the peephole misfires and starts
//      double-freeing, deallocCount diverges from the expected
//      count.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 id;
    void dealloc(void)
    {
        itemDealloc = itemDealloc + 1;
    }
}

// Takes two strong-pointer params but never touches them. Under
// the peephole, both `a` and `b` skip retain+cleanup entirely.
u8 deadParams(Item* a, Item* b, u8 value)
{
    return value + 1;
}

// Uses only `a`. `b` is dead → its retain+cleanup elides; `a`
// keeps the retain+cleanup pair.
u8 mixed(Item* a, Item* b)
{
    return a.id;
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;

    Item* x = new Item();
    x.id = 7;
    Item* y = new Item();
    y.id = 9;

    // deadParams doesn't touch x or y — no refcount churn.
    u8 r1 = deadParams(x, y, 40);
    Assert.isEqual(r1, 41);                       // T1 function returns correctly
    Assert.isEqual(itemDealloc, 0);               // T2 no premature dealloc

    // mixed reads a.id; b is ignored.
    u8 r2 = mixed(x, y);
    Assert.isEqual(r2, 7);                        // T3 body ran, read x.id
    Assert.isEqual(itemDealloc, 0);               // T4 neither x nor y released

    // Scope-exit of main releases x and y → two deallocs.
    Assert.summary();
    return;
}
