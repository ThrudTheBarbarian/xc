//xtc-na: arm64,arm9,m68k,x86_64,win64 — asserts xt6502 5-byte-float precision output
#import "Stdio.xc"
#import "Time.xc"


#define size 8190
#define sizepl 8191

bool flags[sizepl];

void main(void)
	{

	Stdio.printf("10 iterations\n");
		Time.clearTimer();

	u16 count;
	for (u8 iter=1; iter <=10; iter ++)
		{
		count = 0;
		for (u16 i=0; i<=size; i++)
			flags[i] = true;
		
		for (u16 i=0; i<=size; i++)
			{
			if (flags[i])
				{
				u16 prime = i+i+3;
				u16 k = i+prime;
				while (k<=size)
					{
					flags[k] = false;
					k += prime;
					}
				count ++;
				}
			}
		}
	float dt = Time.secondsSince(0);
	
	Stdio.printf("Time: %f secs\nPrimes:%d\n", dt, count);
	if (count == 1899) { Stdio.printf("T1 PASS\n"); }
	else               { Stdio.printf("T1 FAIL expected=1899 got=%u\n", count); }
	}