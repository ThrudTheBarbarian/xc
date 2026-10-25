// select_sink.xc — a float select's true value computed after the branch
// (2026-10-25, perlin's `c ? 0.0 - u : u`): an add, subtract, multiply or
// divide whose one use is the true arm is made only when the condition holds.
// f32 and f64, each of the four operations, a true value that reads the false
// value (which the result is loaded with first), one that reads a value dying
// at the select, and a sunk value in a loop that carries the result.

#import "Stdio.xc"

float neg(u32 h, float u)
	{
	return (h & 1) != 0 ? 0.0 - u : u;
	}

double pickd(u32 h, double a, double b)
	{
	double s = (h & 2) != 0 ? a / b : b;
	double t = (h & 4) != 0 ? a - b : a;
	return s + t;
	}

float scale(u32 h, float u, float v)
	{
	float w = u * 0.5;
	return (h & 8) != 0 ? w * v : w;
	}

float acc(u32 n)
	{
	float x = 1.0;
	for (u32 i = 0; i < n; i++)
		x = (i & 3) == 0 ? x + 0.25 : x * 0.75;
	return x;
	}

void main(void)
	{
	float fs = 0.0;
	double ds = 0.0;
	for (u32 h = 0; h < 32; h++)
		{
		fs = fs + neg(h, (float)h * 0.5 + 1.0) + scale(h, (float)h, 3.0 - (float)h * 0.25);
		ds = ds + pickd(h, (double)h + 0.5, 2.0 + (double)(h & 7));
		}
	Stdio.printf("f %d d %d a %d\n", (i32)(fs * 1000.0), (i32)(ds * 1000.0), (i32)(acc(41) * 1000000.0));
	}
