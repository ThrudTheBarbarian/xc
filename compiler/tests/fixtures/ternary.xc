#import "Stdio.xc"

void main()
	{
	u8 x = 5;
	u8 y = x + 1;		// 6

	// x > y is false -> false-branch
	u8 a = (x > y) ? $4C : $D1;	// 209
	// x < y is true -> true-branch
	u8 b = (x < y) ? $3A : $5A;	// 58

	Stdio.printf("%d %d\n", (i16)a, (i16)b);	// 209 58
	}
