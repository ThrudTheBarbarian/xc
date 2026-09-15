#import "Stdio.xc"
void main(void)
	{
	u8 w = 3;
	u8 witer = 0;
	while (w > 0)
		{
		w --;
		witer ++;
		}

	u8 vals[] = {4, 5,6,7, 8, 9};

	u8 t = 0;
	for (u8 val in vals)
		t += val;

	// standard C style loop
	u8 v = 32;
	for (u8 i=0; i<5; i++)
		{
		v ++;
		}

	Stdio.printf("witer=%u t=%u v=%u\n", (u16)witer, (u16)t, (u16)v);
	}