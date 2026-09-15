// class-arc — strong-slot assignment + scope-exit teardown. Pins the
// canonical ARC IR shape: `new T()` doesn't emit a Retain (the
// allocator hands out a +1 ownership transfer), borrowed-reference
// assignment does. Scope exit Releases every strong local in LIFO
// order.
class Box
    {
    u8 tag;
    }

    void
    run(void)
    {
    Box* a = new Box(); // no Retain — new transfers +1
    Box* b = a;         // Retain a (borrowed reference)
    // scope exit: Release b, then Release a
    }
