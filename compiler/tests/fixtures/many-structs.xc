// many-structs.xc — many struct locals (frame pressure); distinct
// structs must not alias each other.
#import "Stdio.xc"

void main()
	{

	typedef struct {
		u32 a;
		u32 b;
		u32 c;
		u32 d;
		} Block;

	Block a,b,c,d,e,f,g,h,y,u;

	a = {$11110000, $22220000, $33330000, $44440000};
	u = {$aaaa0000, $bbbb0000, $cccc0000, $dddd0000};
	e = {$5a5a0000, $3a3a0000, $d1d10000, $beef0000};

	// Prove the three are independent slots in the frame.
	Stdio.printf("a=%lx,%lx u=%lx,%lx e=%lx,%lx\n",
		a.a, a.d, u.a, u.d, e.b, e.d);
	}
