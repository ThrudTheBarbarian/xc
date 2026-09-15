i16 classify(i16 n)
    {
    if (n < 0)
        return 1;
    else if (n == 0)
        return 2;
    return 3;
    }
i16 main()
    {
    return classify(7);
    }
