// lea_peep.xc — the x86-64 lea peephole (2026-10-25): `mov a, b; add a, c`
// is `lea a, [b+c]`, `add a, k` and `sub a, k` are `[b+k]` and `[b-k]`, and
// a zero-extending `mov r, r` after a 32-bit write is dropped. Sums that keep
// both operands live, at 32 and 64 bits, with negative and large constants,
// a register added to itself, and an add whose flags a compare reads.

#import "Stdio.xc"

u32 tab[64];

u32 mix(u32 a, u32 b)
	{
	u32 s = a + b;
	u32 t = a + 7;
	u32 u = b - 9;
	u32 v = a + a;
	return s * 3 + t * 5 + u * 7 + v + a + b;
	}

i64 wide(i64 a, i64 b)
	{
	i64 s = a + b;
	i64 t = a - 100000;
	i64 u = b + 2000000000;
	return s * 3 + t + u + a + b;
	}

void main(void)
	{
	for (u32 i = 0; i < 64; i++)
		tab[i] = (i * 37 + 11) & 63;
	u32 acc = 0;
	i64 wacc = 0;
	u32 hits = 0;
	for (u32 i = 0; i < 64; i++)
		{
		u32 x = tab[i];
		u32 y = tab[(x + i) & 63];
		u32 z = tab[(y + 1) & 63];
		acc = acc + mix(x, y) + z;
		u32 n = x + y;
		if (n > 60)
			hits = hits + 1;
		wacc = wacc + wide((i64)x - 30, (i64)y * 1000);
		}
	Stdio.printf("acc %u hits %u wide %ld\n", acc, hits, wacc);
	}
