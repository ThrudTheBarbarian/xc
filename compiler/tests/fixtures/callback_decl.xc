// callback_decl.xc — the `callback` spelling of a bound method (0.5).
//
// `callback` mirrors `block`: the keyword is the KIND, THE NAME IS THE SECOND
// TOKEN, and the signature trails it. It replaces the sigil form, which needed
// a typedef first just to have something for `^` to bind to.
//
// It is NEW SYNTAX FOR AN EXISTING TYPE. Both spellings end in the same
// interned `$bound_<signature>` type, so they are assignable in BOTH
// directions with no conversion — which is what this fixture pins. If the two
// ever stop interning together, the cross-assignments below stop compiling.
//
// A callback is NOT a block: a block owns its captures, a callback never owns
// its receiver and auto-zeroes when stored. See private:docs/Design/bound-methods.md §7.
#use Stdio

typedef void act_t(i32);

class Counter
{
    i32 total;
    void init(void) { total = (i32)0; }
    void add(i32 n) { total = total + n; }
}

i32 main(void)
{
    Counter* c = new Counter();

    callback f void(i32 n);          // new spelling, no typedef needed
    f = &c.add;
    if (f) { f((i32)7); }
    if (f) { f((i32)5); }

    act_t^ old = f;                  // new -> transitional sigil
    if (old) { old((i32)3); }

    callback back void(i32 n);
    back = old;                      // transitional sigil -> new
    if (back) { back((i32)1); }

    Stdio.printf("total=%d\n", c.total);
    return 0;
}
