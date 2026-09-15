i16, i16 swp(i16 a, i16 b)
    {
    return b, a;
    }
i16 main()
    {
    i16 x;
    i16 y;
    (x, y) = swp(3, 10);
    return x * 10 + y;
    }
