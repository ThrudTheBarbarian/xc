i16 main()
    {
    i32 a;
    i32 b;
    a = 1000;
    b = 7;
    i32 q;
    i32 r;
    i32 p;
    p = a * b;               // 7000
    q = a / b;               // 142
    r = a % b;               // 6
    return (i16)(p - q - r); // 7000 - 142 - 6 = 6852 -> &0xFF
    }
