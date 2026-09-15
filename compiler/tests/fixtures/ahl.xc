// ahl's benchmark, converted to xtc.
//
// Math.setSeed(1) pins the PRNG state to a known starting value
// so the Random column is reproducible across runs — without it
// xt6502's Math.init reads $D20A (POKEY hardware random) at boot
// and arm64's reads a host-clock-derived value, both of which
// drift the result every time the simulator changes its tick
// model. The accuracy column depends only on float precision, so
// it stays per-backend (xt6502's 5-byte float drifts; arm64's
// IEEE double resolves to zero) — the corpus matches each
// backend against its own oracle (`ahl.expected.<arch>.out`).

#import "Stdio.xc"
#import "Time.xc"

void main(void)
	{
	Math.setSeed((u16)1);

	float r = 0;
	float s = 0;

	Stdio.printf("Begin\n");
	Time.clearTimer();
	
	for (u8 n=1; n<=100; n++)
		{
		float a = n;
		for (u8 i=1; i<=10; i++)
			{
			a = Math.sqrt(a);
			r += Math.rand();
			}
		
		for (u8 i=1; i<=10; i++)
			{
			a = Math.pow(a,2);
			r += Math.rand();
			}
		s += a;
		}
	
	Stdio.printf("Accuracy   %f\n", 1010.0d - s/5.0);
	Stdio.printf("Random     %f\n", Math.abs(1000.0-r));
	// Time column omitted: xt6502's xts clock doesn't advance during the
	// loop (no jiffy ticks fire), and arm64's host clock reads vary at
	// microsecond resolution across runs. Both are real, neither is
	// reproducible against a static oracle — leave it for the user to
	// time interactively when they care.
	}


// Float timings:
//  Accuracy   : -0.001312
//  Random     : 502.707031
//  Time taken : 11.399999 secs


// Double timings:
//  Accuracy   : 0.0000000002
//  Random     : 509.2775831797
//  Time taken : 35.379997 secs
