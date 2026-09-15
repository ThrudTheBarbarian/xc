// many-vars.xc — many live i32 locals (register/frame pressure).
// Each holds a distinctive value; summing all of them proves none
// were clobbered or aliased. Count is sized to fit the xt6502
// 119-byte SP-frame budget.
#import "Stdio.xc"

void main(void)
	{
	i32 v1 = $0100;
	i32 v2 = $0200;
	i32 v3 = $0300;
	i32 v4 = $0400;

	i32 v5 = $0500;
	i32 v6 = $0600;
	i32 v7 = $0700;
	i32 v8 = $0800;

	i32 v9 = $0900;
	i32 w1 = $0a00;
	i32 w2 = $0b00;
	i32 w3 = $0c00;

	i32 w4 = $0d00;
	i32 w5 = $0e00;
	i32 w6 = $0f00;
	i32 w7 = $1000;

	i32 w8 = $1100;
	i32 w9 = $1200;
	i32 x1 = $1300;
	i32 x2 = $1400;

	i32 sum = v1+v2+v3+v4+v5+v6+v7+v8+v9
		+ w1+w2+w3+w4+w5+w6+w7+w8+w9
		+ x1+x2;

	Stdio.printf("sum=%lx first=%lx last=%lx\n",
		(u32)sum, (u32)v1, (u32)x2);
	}
