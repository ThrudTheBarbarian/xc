#import "Stdio.xc"

void main()
	{


	{ // 8-bit
	i8 v1 = 9;
	i8 v2 = 50;

	i8 ti8  = v2 % v1;	// 50 % 9 = 5
	Stdio.printf("%d\n", (i16)ti8);
	}

	{ // 16-bit
	i16 v1 = 37;
	i16 v2 = 600;

	i16 ti16	= v2 % v1;	// 600 % 37 = 8
	Stdio.printf("%d\n", ti16);
	}

	{ // 32-bit
	i32 v1 = 1234;
	i32 v2 = 567890;

	i32 ti32	= v2 % v1;	// 567890 % 1234 = 250
	Stdio.printf("%ld\n", ti32);
	}

	}
