// float_select_homes.xc — the x86 float paths C perlin exercises: a float
// select on an integer condition (fused into the select, shared by two
// selects, and with the true value already in the result's register), more
// loop-carried floats than there are xmm homes (some live in slots and are
// copied there on the back edge), u32 array indices zero-extended between
// registers, and a compare whose boolean is read twice. Every path must give
// the same answer as arm64.

#import "Stdio.xc"

u32 perm[512];

float grad(u32 h, float x, float y)
	{
	u32 g = h & 7;
	float u = g < 4 ? x : y;
	float v = g < 4 ? y : x;
	float a = (g & 1) != 0 ? 0.0 - u : u;
	float b = (g & 2) != 0 ? 0.0 - 2.0 * v : 2.0 * v;
	return a + b;
	}

// The true value is the result's own register when it dies at the select.
float pick(float a, float b, i32 k)
	{
	float t = a * b;
	float r = k > 3 ? t : b;
	return r + a;
	}

// Sixteen floats carried round one loop: more than the fourteen homes.
float carried(u32 n)
	{
	float a0 = 1.0; float a1 = 2.0; float a2 = 3.0; float a3 = 4.0;
	float a4 = 5.0; float a5 = 6.0; float a6 = 7.0; float a7 = 8.0;
	float a8 = 9.0; float a9 = 10.0; float b0 = 11.0; float b1 = 12.0;
	float b2 = 13.0; float b3 = 14.0; float b4 = 15.0; float b5 = 16.0;
	for (u32 i = 0; i < n; i++)
		{
		float t = a0;
		a0 = a1 * 0.5 + 1.0; a1 = a2 * 0.5 + 1.0; a2 = a3 * 0.5 + 1.0;
		a3 = a4 * 0.5 + 1.0; a4 = a5 * 0.5 + 1.0; a5 = a6 * 0.5 + 1.0;
		a6 = a7 * 0.5 + 1.0; a7 = a8 * 0.5 + 1.0; a8 = a9 * 0.5 + 1.0;
		a9 = b0 * 0.5 + 1.0; b0 = b1 * 0.5 + 1.0; b1 = b2 * 0.5 + 1.0;
		b2 = b3 * 0.5 + 1.0; b3 = b4 * 0.5 + 1.0; b4 = b5 * 0.5 + 1.0;
		b5 = t * 0.5 + 1.0;
		}
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + b0 + b1 + b2 + b3 + b4 + b5;
	}

void main(void)
	{
	u32 seed = 12345;
	for (u32 i = 0; i < 256; i++)
		perm[i] = i;
	for (u32 i = 0; i < 256; i++)
		{
		seed = seed * 1103515245 + 12345;
		u32 j = i + (seed >> 16) % (256 - i);
		u32 t = perm[i];
		perm[i] = perm[j];
		perm[j] = t;
		}
	for (u32 i = 0; i < 256; i++)
		perm[i + 256] = perm[i];

	// grad over every hash and a spread of offsets, through u32 indices.
	float gsum = 0.0;
	u32 neg = 0;
	for (u32 i = 0; i < 4096; i++)
		{
		u32 X = i & 255;
		u32 Y = (i >> 4) & 255;
		float xf = (float)(i % 7) / 7.0;
		float yf = (float)(i % 11) / 11.0;
		u32 aa = perm[perm[X] + Y];
		u32 bb = perm[perm[X + 1] + Y + 1];
		float g = grad(aa, xf, yf) + grad(bb, xf - 1.0, yf - 1.0);
		bool lo = g < 0.0;
		if (lo)
			neg = neg + 1;
		gsum = gsum + (lo ? 0.0 - g : g);
		}
	Stdio.printf("grad %d neg %u\n", (i32)(gsum * 1000.0), neg);

	float psum = 0.0;
	for (i32 k = 0; k < 8; k++)
		psum = psum + pick((float)k + 0.5, 3.0, k);
	Stdio.printf("pick %d\n", (i32)(psum * 100.0));

	Stdio.printf("carried %d %d\n", (i32)(carried(3) * 1000.0), (i32)(carried(40) * 1000.0));
	}
