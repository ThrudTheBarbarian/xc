// opt_licm_splat_indirect_call.xc — LICM does not hoist a vector splat out of a loop that calls through a
// function pointer (#434): the callee overwrites the caller-saved vector
// register the splat was kept in.
#import "Stdio.xc"

typedef i32 work_t(i32*, i32);

i32 work(i32* b, i32 k)
    {
    for (i32 i = 0; i < 16; i = i + 1)
        {
        b[i] = b[i] + k;
        }
    return 0;
    }

i32 call(work_t* f, i32* b, i32 k) { return f(b, k); }

i32 run(i32* a, i32* b, i32 k, i32 reps, work_t* cb)
    {
    i32 s = 0;
    for (i32 r = 0; r < reps; r = r + 1)
        {
        for (i32 i = 0; i < 16; i = i + 1)
            {
            a[i] = a[i] + k;
            }
        s = s + call(cb, b, 1000);
        }
    return s;
    }

void main(void)
    {
    i32* a = new i32[16];
    i32* b = new i32[16];
    for (i32 i = 0; i < 16; i = i + 1)
        {
        a[i] = 0;
        b[i] = 0;
        }
    i32 s = run(a, b, 1, 3, &work);
    Stdio.printf("a[0]=%d a[15]=%d b[0]=%d s=%d\n", a[0], a[15], b[0], s);
    }
