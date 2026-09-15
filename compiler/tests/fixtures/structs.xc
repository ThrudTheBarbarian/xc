// structs.xc — struct declaration and usage
//
// Imports the Atari-only System platform library; no arm64 equivalent,
// so this runs on the xt6502 backend only.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — imports an Atari-only platform library

#import <Stdio.xc>
#import <System.xc>

typedef struct {
    u16 x;
    u8 y;
} Cursor;


void main(void)
	{
    Cursor c = {10, 20};
    
    if (c.x != 10)
    	die("cannot set c.x to 10");
    
    if (c.y != 20)
    	die("cannot set c.y to 20");
    	
    u16 px = c.x;
    if (px != 10)
    	die("cannot fetch c.x");
    
	u8 py = c.y;
    if (py != 20)
    	die("cannot fetch c.y");

	Stdio.printf("PASS\n");
	return;
	}


void die(string msg)
	{
	Stdio.printf("FAIL : %s\n", msg);
	System.exit(-1);
	}