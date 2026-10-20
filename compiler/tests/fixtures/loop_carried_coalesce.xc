// loop_carried_coalesce.xc — a loop-carried value shares its phi's register in
// a loop of several blocks only when nothing reads the old value after the new
// one is written. Each loop here reads the OLD value after the update in a
// different way (directly, through a compare fused into the branch, through an
// index folded into a load's address, through a product fused into a later
// add, by leaving the loop from a block other than the header), next to the
// mandelbrot shape where sharing is right. The floats are small integers, so a
// fused multiply-add rounds exactly as a multiply and an add: every target
// prints the same.

#import "Stdio.xc"

class Node
	{
	i32 val;
	Node* next;
	}

u32 data[64];

// x and y carried through two blocks (the escape test, then the update); the
// new y is written by the instruction that reads the old y last.
u32 orbit(float cx, float cy)
	{
	float x = 0.0;
	float y = 0.0;
	u32 k = 0;
	while (k < 64 && x * x + y * y < 64.0)
		{
		float xt = x * x - y * y + cx;
		y = 2.0 * x * y + cy;
		x = xt;
		k = k + 1;
		}
	return k * 1000 + (u32)(x * x + y * y);
	}

// The old k is read after k + 1: as a value, and as a load index.
u32 lagged(u32 n)
	{
	u32 k = 0;
	u32 s = 0;
	while (k < n)
		{
		if (data[k] == 99)
			break;
		u32 j = k;
		k = k + 1;
		s = s + data[j] * j + j;
		}
	return s * 100 + k;
	}

// The old k is compared after the update, in a branch of its own.
u32 compared(u32 n)
	{
	u32 k = 0;
	u32 hits = 0;
	while (k < n)
		{
		if (data[k] == 99)
			break;
		u32 old = k;
		k = k + 2;
		if (old < 10)
			hits = hits + 1;
		}
	return hits * 100 + k;
	}

// The old pointer is dereferenced after the walk has stepped past it.
i32 walk(Node* head)
	{
	Node* p = head;
	i32 s = 0;
	while (p != (Node*)0)
		{
		if (p.val < 0)
			break;
		Node* q = p;
		p = p.next;
		s = s * 3 + q.val;
		}
	return s;
	}

// x*x has two uses, and the second sum is in a later block than the first:
// the multiply is fused into both, reading x where the sums are.
float products(u32 n)
	{
	float x = 1.0;
	float acc = 0.0;
	for (u32 i = 0; i < n; i++)
		{
		float xx = x * x;
		float a = xx + 1.0;
		if (a > 1000.0)
			break;
		acc = acc + (xx - 2.0) + a;
		x = x + 1.0;
		}
	return acc;
	}

// Leaves from the middle block with the old value: the exit reads it.
u32 midExit(u32 n)
	{
	u32 k = 1;
	u32 last = 0;
	while (k < n)
		{
		u32 nk = k * 3;
		if (data[k % 64] == 11)
			{
			last = k;
			break;
			}
		k = nk;
		}
	return last * 1000 + k;
	}

void main(void)
	{
	for (u32 i = 0; i < 64; i++)
		data[i] = (i * 7) % 13;
	data[40] = 99;

	u32 o = 0;
	for (i32 a = -4; a <= 2; a++)
		for (i32 b = -2; b <= 2; b++)
			o = o * 31 + orbit((float)a * 0.5, (float)b * 0.5);
	Stdio.printf("orbit %u\n", o);
	Stdio.printf("lagged %u %u\n", lagged(30), lagged(60));
	Stdio.printf("compared %u %u\n", compared(30), compared(60));

	Node* head = (Node*)0;
	for (i32 i = 1; i <= 6; i++)
		{
		Node* n = new Node();
		n.val = i;
		n.next = head;
		head = n;
		}
	Stdio.printf("walk %d\n", walk(head));
	Stdio.printf("products %d\n", (i32)products(20));
	Stdio.printf("midExit %u %u\n", midExit(100), midExit(5));
	}
