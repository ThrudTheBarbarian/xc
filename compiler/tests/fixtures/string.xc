// string.xc — string literals and char handling.
#import "Stdio.xc"

void main()
	{
	string s = "hi there";
	u8 c = 'X';			// 0x58 = 88

	Stdio.printf("s=%s c=%d\n", s, (u16)c);
	}
