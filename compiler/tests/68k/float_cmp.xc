i16 main()
    {
    double x;
    x = 10.0;
    double y;
    y = 3.0;
    double q;
    q = x / y; // 3.333...
    i16 r;
    r = 0;
    if (q > 3.0)
        r = r + 1;
    if (q < 4.0)
        r = r + 1;
    if (x == 10.0)
        r = r + 1;
    return r; // 3
    }
