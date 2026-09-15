struct Point
    {
    i16 x;
    i16 y;
    };
i16 main()
    {
    Point p;
    p.x = 10;
    p.y = 32;
    i16 arr[4];
    arr[0] = 5;
    arr[1] = 7;
    return p.x + p.y + arr[0] + arr[1];
    }
