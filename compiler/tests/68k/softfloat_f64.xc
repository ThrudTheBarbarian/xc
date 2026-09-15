i16 main()
    {
    double a;
    a = 10000.5;
    double b;
    b = 0.5;
    double c;
    c = a + b; // 10001.0
    double d;
    d = a - b; // 10000.0
    double e;
    e = a + a;                   // 20001.0
    return (i16)(c - d - d + e); // 10001 - 10000 - 10000 + 20001 = 10002 -> &0xFF = 18
    }
