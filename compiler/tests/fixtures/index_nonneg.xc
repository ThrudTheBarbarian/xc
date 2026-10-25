// index_nonneg.xc — a signed 32-bit index known to be non-negative is read as
// its 64-bit register (2026-10-25): `t[h & 255]` and `t[(h & 255) + 1]` need
// no movsxd, as an unsigned index needs none. A mask with the top bit set and
// a negative index beside them still sign-extend.

#import "Stdio.xc"

i32 t[520];

i32 lookups(i32 h)
	{
	i32 x = h & 255;
	i32 a = t[x];
	i32 b = t[x + 1];
	i32 c = t[(h & 127) + 256];
	return a * 3 + b * 5 + c;
	}

i32 backwards(i32* p, i32 k)
	{
	return p[k - 4];
	}

i32 topbit(i32 h)
	{
	i32 m = h & (i32)0x800000FF;
	return m < 0 ? -1 : t[m];
	}

void main(void)
	{
	for (i32 i = 0; i < 520; i++)
		t[i] = i * 7 - 1000;
	i64 sum = 0;
	for (i32 h = -300; h < 3000; h = h + 7)
		sum = sum + (i64)lookups(h) + (i64)topbit(h);
	Stdio.printf("sum %ld back %d %d\n", sum, backwards(&t[10], 1), backwards(&t[10], 6));
	}
