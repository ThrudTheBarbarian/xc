// self-method-call — a method calling a sibling method via implicit
// self (no explicit `self.` receiver). The parser models `_bump()`
// as a bare free-function call; lowering must recognise it as a
// method on the current self and prepend self. _bump() increments
// _n; run() calls it three times, so count3() returns 3 only if the
// implicit-self dispatch works (otherwise the calls vanish → 0).
class Counter
    {
    u16 _n;

    void init(void)
        {
        _n = (u16)0;
        }

    void _bump(void)
        {
        _n = _n + (u16)1;
        }

    u16 run(void)
        {
        _bump();
        _bump();
        _bump();
        return _n;
        }
    }

    u16
    count3(void)
    {
    Counter* c = new Counter();
    return c.run();
    }
