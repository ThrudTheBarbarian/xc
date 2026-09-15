// printf.xc — test formatted output via Stdio class
//
// Pulls in the Atari-only Math / Time platform libraries; no arm64
// equivalent, so this runs on the xt6502 backend only.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — asserts xt6502 5-byte-float precision output

#import <Math.xc>
#import <Stdio.xc>
#import <Time.xc>

typedef struct 
	{
	u8 r;
	u8 g;
	u8 b;
	} RGB;
	
typedef struct
	{
	u16 x;
	u8 y;
	RGB rgb;
	} Point;
	
void main(void)
	{
    Stdio.printf("Hello world!\n");
    Stdio.printf("Score: %d ", 1000);
    Stdio.printf("100%% done\n");
 
    string name = "Atari";
    Stdio.printf("Name: %s", name);
 
    Stdio.printfAt(10, 5, "At 10,5: %d", 42);
    Stdio.printfAt(10, 3, "At 10,3: %d", 42);
 
	Stdio.printf("\nPi: %f\n", Math.PI());
	
	u32 lval = $deadbeef;
	Stdio.printf("long: %lx\n", lval);
	
	Point t = {30,40, {5,6,7}};
	// `%@` on a struct is not supported yet (the dispatch goes through
	// the class-only `obj.description()` path). Print the fields
	// directly until struct `%@` lands via a synthesised descriptor +
	// printStruct walker.
	Stdio.printf("Point: (%u, %u, (%u,%u,%u))\n",
	             t.x, (u16)t.y, (u16)t.rgb.r, (u16)t.rgb.g, (u16)t.rgb.b);

	Time.delayJiffies(6);   // ~0.1s real wait — exercises the host clock path
    return;
	}
