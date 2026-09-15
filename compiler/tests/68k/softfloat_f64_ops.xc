i16 main()
    {
    double a;
    a = 12.5;
    double b;
    b = 4.0;
    double s;
    s = a + b;
    double d;
    d = a - b;
    double m;
    m = a * b;
    double q;
    q = a / b;
    return (i16)s + (i16)d + (i16)m + (i16)(q * 8.0); // 16+8+50+25=99
    }
