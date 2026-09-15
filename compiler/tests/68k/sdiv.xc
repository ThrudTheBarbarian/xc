#import "Stdio.xc"
i16 main()
    {
    i32 a;
    a = 0 - 100;
    i32 b;
    b = 7;
    Stdio.print("q=");
    Stdio.print((i32)(a / b));
    Stdio.print(" r=");
    Stdio.print((i32)(a % b));
    Stdio.print("\n");
    return 0;
    }
