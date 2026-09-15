#import "Stdio.xc"

void main()
	{
	u8 vals[6] = {3,4,5,6,7,8};
	u8 t = 0;
	for (u8 val in vals)
		t += val;

	// t = 33 > 30 -> take the if-branch
	if (t > 30)
		t -= 10;
	else
		t += 10;
	Stdio.printf("%d\n", (i16)t);		// 23

	u8 small[4] = {2,3,4,5};
	u8 s = 0;
	for (u8 val in small)
		s += val;

	// s = 14 <= 30 -> take the else-branch
	if (s > 30)
		s -= 10;
	else
		s += 10;
	Stdio.printf("%d\n", (i16)s);		// 24
	}
