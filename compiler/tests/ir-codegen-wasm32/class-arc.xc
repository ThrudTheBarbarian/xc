// Classes on wasm32: vtable words are funcref-table indices, dispatch is
// call_indirect, ARC refcounts live at payload-2, and new/delete go through
// the in-module free-list allocator. Sentinel values, not 0/FF.
extern void putw(i32 v);

class Counter
    {
    i32 total;

    void bump(i32 n)
        {
        self.total = self.total + n;
        }

    i32 value(void)
        {
        return self.total;
        }
    }

    void
    main(void)
    {
    Counter* c = new Counter();
    c.bump(5);
    c.bump(7);
    putw(c.value()); // 12 (heap-new zero-inits ivars)
    putw(77);        // ARC releases c at scope exit (through the free-list)
    }
