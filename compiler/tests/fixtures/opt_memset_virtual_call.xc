// opt_memset_virtual_call.xc — the memset idiom keeps a byte-clearing loop that also makes a virtual
// method call (#434). Made into a MemSet, the loop lost its calls.
#import "Stdio.xc"

i32 ticks;

class Counter
    {
    i32 pad;
    void tick(void) { ticks = ticks + 1; }
    }

class C2 : Counter { void tick(void) { ticks = ticks + 2; } }
class C3 : Counter { void tick(void) { ticks = ticks + 3; } }
class C4 : Counter { void tick(void) { ticks = ticks + 4; } }
class C5 : Counter { void tick(void) { ticks = ticks + 5; } }
class C6 : Counter { void tick(void) { ticks = ticks + 6; } }

void clear(u8* buf, Counter* c)
    {
    for (u32 i = 0; i < 16; i = i + 1)
        {
        buf[i] = 0;
        c.tick();
        }
    }

void main(void)
    {
    u8* buf = new u8[16];
    ticks = 0;
    clear(buf, new Counter());
    clear(buf, new C2());
    clear(buf, new C3());
    clear(buf, new C4());
    clear(buf, new C5());
    clear(buf, new C6());
    Stdio.printf("ticks=%d\n", ticks);
    }
