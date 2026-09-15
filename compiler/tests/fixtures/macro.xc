// macro.xc — function-like macros (incl. a backslash line continuation)
// and an enum. The macro results are printed so the test proves the
// preprocessor expansion happened, while staying portable across targets.
#import "Stdio.xc"

#define ADD(x) ((x)+1)

#define SUB(x) ((x) - \
				1)

enum suits = {hearts, clubs, diamonds, spades };

void main()
	{
	u8 a = ADD($59);          // ($59)+1 = $5A (90)
	u8 s = SUB($5C);          // ($5C)-1 = $5B (91)
	u8 e = ADD((u8)spades);   // spades=3, +1 = 4
	Stdio.printf("%d %d %d\n", (u16)a, (u16)s, (u16)e);
	}
