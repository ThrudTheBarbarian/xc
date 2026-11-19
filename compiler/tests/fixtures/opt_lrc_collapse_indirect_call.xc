// opt_lrc_collapse_indirect_call.xc — loop-reduction collapse does not run an outer loop once when its
// inner loop calls through a function pointer (#433): the callback must run
// 4 * n times.
#import "Stdio.xc"

class Box
    {
    i32 calls;
    }

typedef i32 step_t(Box*, i32);

i32 step(Box* b, i32 i) { b.calls = b.calls + 1; return i; }

i32 call(step_t* f, Box* b, i32 i) { return f(b, i); }

i32 run(Box* b, step_t* cb, i32 n)
    {
    i32 acc = 0;
    for (i32 rep = 0; rep < 4; rep = rep + 1)
        {
        for (i32 i = 0; i < n; i = i + 1)
            {
            acc = acc + call(cb, b, i);
            }
        }
    return acc;
    }

void main(void)
    {
    Box* b = new Box();
    b.calls = 0;
    i32 r = run(b, &step, 10);
    Stdio.printf("acc=%d calls=%d\n", r, b.calls);
    }
