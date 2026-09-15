// `return self` from a heap-receiver method must not leak a count
// (private:docs/bugs/058).
//
// A heap receiver gives the method a prologue `Retain self`, and `return
// self` pays the ordinary borrowed-return retain — so the prologue's count
// must be released in the epilogue like any other path. The original's
// returning-value exemption used to swallow that release: every call to a
// `return self` method left the receiver one count high, and the object
// below never deallocated. Three calls, then delete: with the leak the
// refcount sits at 4 and "dealloc ran" never prints. The cast spelling
// `return (Box*)self` never took the exemption (a Bitcast is a new value)
// and was already balanced — both spellings are pinned so they cannot
// diverge again.
#import "Stdio.xc"

class Box
{
    u32 n;
    void init(void) { n = (u32)7; }

    Box* give(void)
    {
        return self;
    }

    Box* giveCast(void)
    {
        return (Box*)self;
    }

    void dealloc(void)
    {
        Stdio.printf("dealloc ran\n");
    }
}

i32 main(void)
{
    {
        Box* b = new Box();
        // Each call's +1 result is a statement temp, released at end of
        // statement; only the callee-side balance is under test.
        b.give();
        b.give();
        b.giveCast();
        Stdio.printf("n=%ld\n", b.n);
    }
    // The scope exit above holds b's ONLY count once the calls balance —
    // dealloc must have printed by here. With the leak it never does.
    Stdio.printf("after scope\n");
    return 0;
}
