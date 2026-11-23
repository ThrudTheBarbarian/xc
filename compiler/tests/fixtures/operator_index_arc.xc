// Index operators whose elements are objects. `shelf[i]` hands back a +1
// temporary that the end of the full expression releases unless something
// keeps it; `shelf[i] = shelf[j]` passes one get's result straight to the set,
// which keeps its own reference. `shelf[i] += n` is get, `+`, set: the get's
// result and the sum are temporaries, and the set keeps the sum.
//
// `live` counts Num instances from init to dealloc.
#import <Stdio.xc>

i32 live;

class Num
    {
    i32 v;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    static Num* of(i32 x) { Num* n = new Num(); n.v = x; return n; }
    Num* plus(i32 k) :operator(self + k) { return Num.of(v + k); }
    Num* plusNum(Num* o) :operator(self + o) { return Num.of(v + o.v); }
    }

class Shelf
    {
    Num* slots[4];
    Num* at(i32 i) :operator(self[i]) { return slots[i]; }
    void put(i32 i, Num* n) :operator(self[i] = n) { slots[i] = n; }
    }

void show(Shelf* b)
    {
    Stdio.printf("shelf");
    for (i32 i = 0; i < 4; i = i + 1)
        {
        Num* n = b[i];
        if (n == nil)
            Stdio.printf(" -");
        else
            Stdio.printf(" %d", n.v);
        }
    Stdio.printf(" live %d\n", live);
    }

i32 main(void)
    {
    Shelf* b = new Shelf();
    b[0] = Num.of(1);
    b[1] = Num.of(2);
    show(b);
    b[2] = b[0];
    show(b);
    b[3] = b[0] + b[1];
    show(b);
    b[1] += 40;
    b[3] += b[1];
    show(b);
    for (i32 i = 0; i < 5; i = i + 1)
        b[0] += 1;
    show(b);
    Num* keep = b[3];
    b[3] = Num.of(0);
    Stdio.printf("keep %d live %d\n", keep.v, live);
    keep = 0;
    b = 0;
    Stdio.printf("live %d\n", live);
    return 0;
    }
