i16 main()
    {
    i16 n;
    n = 7;
    float f;
    f = (float)n;
    float g;
    g = 2.5;
    i16 r;
    r = 0;
    if (f > g)
        r = r + 1;
    if (g < f)
        r = r + 1;
    r = r + (i16)g;
    return r;
    }
