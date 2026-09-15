#import "Stdio.xc"

void main()
	{
	i8 x = $5A;		// 90
	i8 y = $3C;		// 60

	i8 and = x & y;		// $18 = 24
	i8 or  = x | y;		// $7E = 126
	i8 xor = x ^ y;		// $66 = 102
	i8 not = ~x;		// ~90 = -91

	Stdio.printf("%d %d %d %d\n", (i16)and, (i16)or, (i16)xor, (i16)not);
	}
