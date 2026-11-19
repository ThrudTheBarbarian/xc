// opt_licm_load_indirect_call.xc — LICM keeps a field load in a loop whose only write is a call through
// a function pointer (#433). The callee changes the field, so hoisted, the
// load read 0 on every trip.
#import "Stdio.xc"

class Box
    {
    i32 x;
    }

typedef i32 bump_t(Box*);

i32 bump(Box* b) { b.x = b.x + 1; return 0; }

i32 run(Box* b, bump_t* cb, i32 n)
    {
    i32 s = 0;
    for (i32 i = 0; i < n; i = i + 1)
        {
        s = s + b.x;
        s = s + cb(b);
        }
    return s;
    }

void main(void)
    {
    Box* b = new Box();
    b.x = 0;
    Stdio.printf("%d\n", run(b, &bump, 10));
    }
