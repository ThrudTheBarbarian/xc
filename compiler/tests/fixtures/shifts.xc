// shifts.xc — proves <<, >>, <: (rotate-left), :> (rotate-right)
// at u8/u16/u32 widths.
#import "Stdio.xc"

void main()
	{
	u8 v8		= $5a;
	u8 asl8		= v8 << 3;
	u8 rol8		= v8 <: 3;
	u8 asr8 	= v8 >> 3;
	u8 ror8 	= v8 :> 3;
	Stdio.printf("u8: %u %u %u %u\n",
		(u16)asl8, (u16)rol8, (u16)asr8, (u16)ror8);

	u16 v16 	= $beef;
	u16 asl16	= v16 << 4;
	u16 rol16	= v16 <: 4;
	u16 asr16 	= v16 >> 4;
	u16 ror16 	= v16 :> 4;
	Stdio.printf("u16: %u %u %u %u\n", asl16, rol16, asr16, ror16);

	u32 v32 	= $deadbeef;
	u32 asl32 	= v32 << 8;
	u32 rol32 	= v32 <: 8;
	u32 asr32 	= v32 >> 8;
	u32 ror32 	= v32 :> 8;
	Stdio.printf("u32: %lx %lx %lx %lx\n", asl32, rol32, asr32, ror32);
	}
