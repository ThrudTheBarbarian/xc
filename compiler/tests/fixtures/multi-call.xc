#import "Stdio.xc"

i8 add(i8 val) :
	{
	return val + 1;
	}

void main(void)
	{
	// add(val) = val + 1, exercised through nested multi-calls
	i8 t  = add(add($57));            // $57(87) + 2 = 89
	i8 t2 = add(add(add($57)));       // 87 + 3 = 90
	i8 t3 = add(add(add(add($57))));  // 87 + 4 = 91
	Stdio.printf("%d %d %d\n", (i16)t, (i16)t2, (i16)t3);
	}
