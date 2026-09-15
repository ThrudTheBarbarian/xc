class Counter
    {
    i16 n;
    void inc()
        {
        n = n + 1;
        }
    i16 get()
        {
        return n;
        }
    } i16 main()
    {
    Counter c;
    c.n = 0;
    c.inc();
    c.inc();
    c.inc();
    return c.get();
    }
