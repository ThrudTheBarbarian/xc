#import "Stdio.xc"
#include "included.xc"

void main(void)
	{
	// incFunc comes from the #included file: incFunc(val) = val + 1
	u16 val = incFunc($59);   // $59 + 1 = $5A (90)
	Stdio.printf("%d\n", val);
	}
