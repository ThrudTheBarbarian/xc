#import "Stdio.xc"

void main()
	{


	{ // 8-bit  (product fits i8)
	i8 v1 = 6;
	i8 v2 = 20;

	i8 pi8	= v1 + v2;	// 26
	i8 mi8  = v1 - v2;	// -14
	i8 di8  = v2 / v1;	// 3
	i8 ti8  = v2 * v1;	// 120
	Stdio.printf("%d %d %d %d\n", (i16)pi8, (i16)mi8, (i16)di8, (i16)ti8);
	}

	{ // 16-bit
	i16 v1 = 37;
	i16 v2 = 600;

	i16 pi16	= v1 + v2;	// 637
	i16 mi16	= v1 - v2;	// -563
	i16 di16	= v2 / v1;	// 16
	i16 ti16	= v2 * v1;	// 22200
	Stdio.printf("%d %d %d %d\n", pi16, mi16, di16, ti16);
	}

	{ // 32-bit
	i32 v1 = 1234;
	i32 v2 = 567890;

	i32 pi32	= v1 + v2;	// 569124
	i32 mi32	= v1 - v2;	// -566656
	i32 di32	= v2 / v1;	// 460
	i32 ti32	= v2 * v1;	// 700776260
	Stdio.printf("%ld %ld %ld %ld\n", pi32, mi32, di32, ti32);
	}

	}
