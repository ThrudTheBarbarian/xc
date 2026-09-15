// numbers.xc — numeric literals (hex $, binary %, underscores,
// negative, u32, float), casts and cross-width assignment.
#import "Stdio.xc"

void main()
	{
	u8 x = $5a;			// 90
	i8 y = -7;

	u16 q = $beef;			// 48879
	i16 w = -512;

	u32 t = 70_000;
	i32 h = $f2_0000;		// 15859712

	float f = -1.5;

	bool b = true;

	u8 bin = %1011_1101;		// 189

	x = (u8)q;			// $beef & 0xFF = $ef = 239
	auto v = (u16)t;		// 70000 & 0xFFFF = 4464

	i8 fi = f;			// -1.5 -> -1

	Stdio.printf("x=%u y=%d\n", (u16)x, (i16)y);
	Stdio.printf("q=%u w=%d\n", q, w);
	Stdio.printf("t=%lu h=%lx\n", t, (u32)h);
	Stdio.printf("bin=%u b=%u\n", (u16)bin, (u16)b);
	Stdio.printf("fi=%d v=%u\n", (i16)fi, v);
	}
