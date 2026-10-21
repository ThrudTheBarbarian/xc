// xtc: error "'total' is an instance field of Tally, and a static method has no instance"
// The store form: a static method writing an instance field changed the
// class's shared __sdata copy, not any Tally. Only a static field may be
// written there.

#import "Stdio.xc"

class Tally
	{
	u32 total;
	static u32 made;
	void add(u32 n) { total = total + n; made = made + 1; }
	static void clear(void) { made = 0; total = 0; }
	}

void main(void)
	{
	Tally* t = new Tally();
	t.add(4);
	Tally.clear();
	Stdio.printf("%u\n", t.total);
	}
