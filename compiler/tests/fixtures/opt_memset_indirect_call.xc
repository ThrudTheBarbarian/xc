// opt_memset_indirect_call.xc — the memset idiom keeps a byte-clearing loop that also calls through a
// function pointer (#434). Made into a MemSet, the loop lost its calls.
#import "Stdio.xc"

typedef i32 tick_t(i32);

i32 ticks;

i32 tick(i32 x)
    {
    ticks = ticks + 1;
    return x;
    }

i32 call(tick_t* f, i32 x) { return f(x); }

void clear(u8* buf, tick_t* cb)
    {
    for (u32 i = 0; i < 16; i = i + 1)
        {
        buf[i] = 0;
        call(cb, 5);
        }
    }

void main(void)
    {
    u8* buf = new u8[16];
    ticks = 0;
    clear(buf, &tick);
    Stdio.printf("ticks=%d\n", ticks);
    }
