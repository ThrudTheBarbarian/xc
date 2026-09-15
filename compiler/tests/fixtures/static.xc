#import "Stdio.xc"

void main(void)
	{
	fn();
	fn();
	}

void fn(void)
	{
	static u8 a = 4;
	a++;
	Stdio.printf("a=%d\n", (u16)a);
	}
