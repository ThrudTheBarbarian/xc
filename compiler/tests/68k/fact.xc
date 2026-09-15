i16 fact(i16 n)
    {
    if (n <= 1)
        return 1;
    return n * fact(n - 1);
    }
i16 main()
    {
    return fact(5);
    }
