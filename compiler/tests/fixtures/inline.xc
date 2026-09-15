#import "Stdio.xc"

void main()
	{
	// inlined call: myFunc(t) = t << 1
	u8 val = inline:myFunc($2D);   // $2D<<1 = $5A (90)

	// ordinary (non-inlined) call to the same function
	u8 val2 = myFunc($68);         // $68<<1 = $D0 (208)

	Stdio.printf("%d %d\n", (u16)val, (u16)val2);
	}

u8 myFunc(u8 t)
	{
	return t<<1;
	}
