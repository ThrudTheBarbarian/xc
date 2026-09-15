// Uses the Atari-only `symbols.xc` platform definitions; no arm64
// equivalent, so this runs on the xt6502 backend only.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — imports an Atari-only platform library
#import "symbols.xc"
#import "Stdio.xc"

void main()
	{
	u16 dlist = SDLSTL;     // $0230 = 560
	u16 ram   = RAMLO;      // $0004 = 4
	Stdio.printf("dlist=%d ram=%d\n", dlist, ram);
	}
