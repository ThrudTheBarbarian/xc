#import "Stdio.xc"

// small leaf function — candidate for the leaf inliner at -O2+
u8 myFn(u8 x)
	{
	return x + (u8)$0A;   // x + 10
	}


void main()
	{
	u8 d = myFn($50);          // $50 + $0A = $5A (90)
	u8 e = myFn(myFn($26));    // 38+10=48, 48+10 = 58
	Stdio.printf("%d %d\n", (u16)d, (u16)e);
	}
