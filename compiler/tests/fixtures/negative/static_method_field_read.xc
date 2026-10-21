// xtc: error "'count' is an instance field of Counter, and a static method has no instance"
// A static method has no instance, so a field it names would be the class's
// one shared __sdata copy, which no instance ever sees: Counter.peek() would
// read 0 for a counter bumped to 3. In a class with instance methods that is
// an error (owner decision 2026-10-20).

#import "Stdio.xc"

class Counter
	{
	i32 count;
	void bump(void) { count = count + 1; }
	static i32 peek(void) { return count; }
	}

void main(void)
	{
	Counter* c = new Counter();
	c.bump();
	Stdio.printf("%d\n", Counter.peek());
	}
