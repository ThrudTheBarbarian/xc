// Free-function overloading smoke test. Also covers the sema-time
// auto-synthesis of per-class `description()` — Example carries no
// hand-written override, so the `%@` format below depends on the
// synthesiser emitting the `<Example>(r, g, b)` body itself.

#import <Stdio.xc>

class Example
	{
	u8 r,g,b;

	void print(u32 val)
		{
		Stdio.printf("u32: %ld", val);
		}

	void print(u8 val)
		{
		Stdio.printf("u8: %d", val);
		}

	void print(string val)
		{
		Stdio.printf("string: %s", val);
		}
	}

void show(u32 v)
    {
    Stdio.printf("u32: %lx\n", v);
    }

void show(string s)
    {
    Stdio.printf("str: %s\n", s);
    }

void show(u8 a, u8 b)
    {
    Stdio.printf("pair: %d,%d\n", a, b);
    }

void main(void)
    {
    show($deadbeef);
    show("hello");
    show(3, 4);
    
    Example* eg = new Example();
    eg.r = 4;
    eg.g = 5;
    eg.b = 6;

    Stdio.printf("example: %@\n", eg);

    return;
    }
