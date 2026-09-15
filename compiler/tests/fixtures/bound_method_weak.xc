// bound_method_weak.xc — `weak:action_t^` auto-zeroes when its target dies.
//
// A `^` NEVER owns its recv (for a widened function that word is a CODE
// address, and retaining it would refcount .text). So `weak:` here does not
// mean "don't retain" — nothing retains it anyway. It means AUTO-ZERO: the
// action goes falsy the instant the receiver dies. AppKit's target semantics.
//
//   T1  a widened free function survives (nothing frees .text)
//   T2  a bound method fires while its receiver is alive
//   T3  ...and the `^` goes FALSY once the receiver dies — it must NOT fire
//       with a null self, which would be worse than a dangling pointer
//
// The registered slot is the `^`'s CODE word, not its recv: zeroing recv would
// leave code non-null, and `if (h)` tests CODE — so the action would still look
// live and would be called with self = 0.
//
//   T4  a widened `^` must NOT consume a weak-table slot. Its recv is a code
//       address; nothing ever dies there, so the entry could never fire and
//       would burn one of the bounded (64) slots forever. 200 widened actions
//       are registered below — far past the table size — and a REAL weak target
//       must still register and still auto-zero afterwards. Without the guard
//       the table would be full and T3 would silently stop working.
#import "Stdio.xc"

typedef u16 act_t(void);

u16 freeFn(void) { return (u16)42; }

class Controller
{
    u16  v;
    void init(void)   { v = (u16)99; }
    u16  save(void)   { return v; }
    void dealloc(void) { Stdio.printf("target-died\n"); }
}

class Button
{
    weak:act_t^ action;
    void setAction(weak:act_t^ a) { action = a; }
    u16  fire(void) { if (action) { return action(); } return (u16)0; }
}

void main(void)
{
    Button* b = new Button();

    // T1: widened free function.
    b.setAction(&freeFn);
    Stdio.printf("free=%d\n", b.fire());

    // T4: flood the weak table with widened actions. These must not register.
    u16 i = (u16)0;
    for (i = (u16)0; i < (u16)200; i = i + (u16)1) {
        Button* junk = new Button();
        junk.setAction(&freeFn);
    }

    // T2/T3: a real target, then let it die.
    {
        Controller* c = new Controller();
        b.setAction(&c.save);
        Stdio.printf("alive=%d\n", b.fire());
    }
    Stdio.printf("dead=%d\n", b.fire());
}
