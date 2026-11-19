// opt_lrc_hoist_indirect_call.xc — loop-reduction collapse does not hoist an inner store loop that calls
// through a function pointer (#433): the callback must run 4 * 16 times.
#import "Stdio.xc"

typedef i32 tick_t(i32);

i32 ticks;

i32 tick(i32 x)
    {
    ticks = ticks + 1;
    return x;
    }

i32 call(tick_t* f, i32 x) { return f(x); }

void fill(i32* b, tick_t* cb)
    {
    for (i32 rep = 0; rep < 4; rep = rep + 1)
        {
        for (i32 i = 0; i < 16; i = i + 1)
            {
            b[i] = 7;
            call(cb, 5);
            }
        }
    }

void main(void)
    {
    i32* b = new i32[16];
    ticks = 0;
    fill(b, &tick);
    Stdio.printf("ticks=%d b[3]=%d\n", ticks, b[3]);
    }
