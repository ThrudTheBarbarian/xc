void _putc(u8 c);
i16 main()
    {
    string s;
    s = "Hello, ST!\n";
    u8 c;
    c = *s;
    while (c != (u8)0)
        {
        _putc(c);
        s = s + 1;
        c = *s;
        }
    return 0;
    }
