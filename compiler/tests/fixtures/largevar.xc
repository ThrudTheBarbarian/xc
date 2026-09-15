// largevar.xc — a large (>256 byte) local array; indexing past 255
// must reach the right slot.
#import "Stdio.xc"

void main()
	{
	u8 val[300];

	val[0]   = $5a;
	val[200] = $d1;
	val[270] = $3a;		// index > 255 needs 16-bit offset
	val[299] = $b7;

	Stdio.printf("%u %u %u %u\n",
		(u16)val[0], (u16)val[200], (u16)val[270], (u16)val[299]);
	}
