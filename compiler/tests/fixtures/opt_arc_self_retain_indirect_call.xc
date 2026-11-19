// opt_arc_self_retain_indirect_call.xc — a method that calls through a function pointer keeps its retain of
// self (#434). The callee drops the last other reference, so without the
// retain the object was freed while the method still ran.
#import "Stdio.xc"

typedef i32 cb_t(i32);

i32 freed;
i32 freedDuringVisit;

class Node
    {
    i32 value;
    void dealloc(void) { freed = 1; }
    i32 visit(cb_t* cb)
        {
        i32 r = cb(value);
        freedDuringVisit = freed;
        return r + value;
        }
    }

Node* holder;

i32 dropHolder(i32 x)
    {
    holder = nil;
    return x;
    }

void main(void)
    {
    freed = 0;
    freedDuringVisit = 0;
    holder = new Node();
    holder.value = 7;
    i32 r = holder.visit(&dropHolder);
    Stdio.printf("r=%d freed during visit=%d\n", r, freedDuringVisit);
    }
