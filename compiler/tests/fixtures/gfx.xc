//xtc-flags: skip
// ^ Timing benchmark with no stable cross-target oracle: the
//   only output is Stdio.printf("…time: %f secs", t) for four
//   operations. The Atari oracle has "0.0 secs" everywhere
//   (the 0.1-second-resolution Time.secondsSince clamps short
//   ops to 0), arm64 produces microsecond-precision values
//   that won't match, and xt6502 times out under the simulator
//   (Atari Gfx perf at 1.79 MHz can't finish the loops in the
//   sim's instruction budget). Same shape as the `sieve`
//   fixture's timing divergence. Skip — benchmark, not a
//   correctness test.
// gfx8_phase1.xc — Gfx/Gfx8 phase 1: state + plot + getPixel + hline.
//

#import "Stdio.xc"
#import "Time.xc"
#import "Gfx8.xc"

void main(void)
{
    Gfx8* g = new Gfx8(4);

	Time.clearTimer();
	g.setPen(0);	
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	g.clear();
	float f1 = Time.secondsSince(0);
	
	u8 minY = 5;
	u8 maxY = 155;
	u16 minX = 5;
	u16 maxX = 315;
	
	Time.clearTimer();
    g.setPen(1);
    for (u8 i = minY; i<maxY; i++)
	    g.hline(minX, maxX, i);
	float f2 = Time.secondsSince(0);

	g.setPen(0);
	
	Time.clearTimer();
	for (u8 i=minY; i<maxY; i+=2)
		g.line(minX,i,maxX, maxY-i+minY);
		
	for (u16 i=minX; i<=maxX; i+=2)
		g.line(i, minY, maxX-i+minX, maxY);
		
	float f3 = Time.secondsSince(0);
	
	Time.clearTimer();
	g.setPen(0);
	g.fillCircle(160, 80, 60);
	
// 	g.setPen(1);
// 	for (u8 i=55; i>=5; i-=5)
// 		g.circle(160, 80,i);
		
	float f4 = Time.secondsSince(0);
	
	Stdio.printf("Clear  time: %f secs\n", f1/10.0);
	Stdio.printf("Hline  time: %f secs\n", f2);
	Stdio.printf("Moire  time: %f secs\n", f3);
	Stdio.printf("Circle time: %f secs\n", f4);
    return;
}

// clear		: 0.057999
// old hline	: 12.599999
// new hline 	: 0.179999
// moire        : 3.31999
// circle       : 0.13999


