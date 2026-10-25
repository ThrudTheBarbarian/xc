// select_mask.xc — selects on a masked bit (2026-10-25, perlin's grad()):
// `(x & 7) < 4` is the bit test `(x & 4) == 0`, `(x & 7) & 1` is `x & 1`,
// and on x86-64 a select whose condition is `(x & m) == 0` or `!= 0` tests x
// against m itself, the And not emitted. Every width of x, float and integer
// selects, a compare read by two selects, a mask whose And has another use,
// the high bit of a byte and of a word, and a 64-bit mask over 31 bits.

#import "Stdio.xc"

float fpick(u32 h, float x, float y)
	{
	u32 g = h & 7;
	float u = g < 4 ? x : y;
	float v = g >= 4 ? y : x;
	float a = (g & 1) != 0 ? 0.0 - u : u;
	float b = (g & 2) == 0 ? v * 2.0 : 0.0 - v * 2.0;
	return a + b + v;
	}

i32 ipick(u32 h, i32 a, i32 b)
	{
	i32 r = (h & 6) < 2 ? a : b;
	i32 s = (h & 8) != 0 ? r + 1 : r - 1;
	return s;
	}

u32 bytehi(u8 c, u32 a, u32 b)
	{
	return (c & 128) != 0 ? a : b;
	}

u32 wordhi(u16 w, u32 a, u32 b)
	{
	return (w & 32768) == 0 ? a : b;
	}

i64 widebit(u64 x, i64 a, i64 b)
	{
	return (x & 1073741824) != 0 ? a : b;
	}

// The And is read twice: by the select's compare and by the sum.
u32 shared(u32 h, u32 a, u32 b)
	{
	u32 m = h & 12;
	u32 r = m == 0 ? a : b;
	return r + m;
	}

void main(void)
	{
	float fs = 0.0;
	i32 is = 0;
	u32 us = 0;
	i64 ws = 0;
	for (u32 h = 0; h < 64; h++)
		{
		fs = fs + fpick(h, (float)h * 0.25, 1.5 - (float)h * 0.125);
		is = is + ipick(h, (i32)h, 100 - (i32)h);
		us = us + bytehi((u8)(h * 5), h, 1000) + wordhi((u16)(h * 1031), h, 2000);
		ws = ws + widebit((u64)h << 25, (i64)h, -1);
		us = us + shared(h, 7, 11);
		}
	Stdio.printf("f %d i %d u %u w %ld\n", (i32)(fs * 1000.0), is, us, ws);
	}
