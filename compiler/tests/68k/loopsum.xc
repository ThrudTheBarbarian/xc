i16 sum(i16 n)
    {
    i16 s;
    s = 0;
    i16 i;
    for (i = 1; i <= n; i = i + 1)
        s = s + i;
    return s;
    }
i16 main()
    {
    return sum(5);
    }
