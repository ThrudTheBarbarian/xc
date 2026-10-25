// dead_store.xc — a store to a local that a later store overwrites, with
// nothing reading memory between, is dropped (2026-10-25: a struct local
// with no initialiser is zero-filled, then assigned field by field). Each
// case below must keep the stores that are read: a field read between two
// stores, a call that may read through a pointer to the local, a store
// through a pointer that may be the local, an array element by a variable
// index, and a store whose next store is to another field.

#import "Stdio.xc"

struct Pt { u32 x, y; }

u32 peek(Pt* p) { return p.x * 3 + p.y; }

Pt bump(Pt p, u32 d) { Pt q; q.x = p.x + d; q.y = p.y ^ d; return q; }

u32 readBetween(u32 a)
	{
	Pt q;
	q.x = a;
	u32 seen = q.x + q.y;      // reads the zero-filled y and the stored x
	q.x = a * 2;
	return seen + q.x;
	}

u32 callBetween(u32 a)
	{
	Pt q;
	q.x = a;
	q.y = 1;
	u32 s = peek(&q);          // the call reads both fields
	q.x = 5;
	return s + q.x;
	}

u32 aliasBetween(u32 a, u32* p)
	{
	u32 v[4];
	v[2] = 100;
	v[1] = a;
	*p = v[1] + 1;             // p may be &v[1]
	v[1] = a + 7;
	return v[1] + v[2];
	}

u32 varIndex(u32 a, u32 i)
	{
	u32 v[4];
	v[0] = 1; v[1] = 2; v[2] = 3; v[3] = 4;
	v[i] = a;
	v[i & 3] = a + 1;
	return v[0] + v[1] + v[2] + v[3];
	}

void main(void)
	{
	Pt p;
	p.x = 3;
	p.y = 5;
	u32 acc = 0;
	for (u32 r = 0; r < 100; r++)
		{
		p = bump(p, r);
		acc = acc + p.x + p.y;
		}
	u32 w[4];
	w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 0;
	u32 al = aliasBetween(9, &w[1]);
	Stdio.printf("%u %u %u %u %u %u\n", acc, readBetween(7), callBetween(4), al, w[1], varIndex(10, 2));
	}
