// static-field — static methods reach class state via the per-class
// __sdata block used as `self`. Counter.n starts at 0 (zeroed
// __sdata, no init needed); three bumps then get() returns 3.
// Validates static-self binding, static call sites, and ivar
// read/write through __sdata on both backends.
class Counter
    {
    u16 n;

    static void bump(void)
        {
        n = n + 1;
        }

    static u16 get(void)
        {
        return n;
        }
    }

    u16
    run(void)
    {
    Counter.bump();
    Counter.bump();
    Counter.bump();
    return Counter.get();
    }
