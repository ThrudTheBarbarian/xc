// retain_pair.xc — a Retain and a Release of the same value with only pure
// instructions between cancel (2026-10-25: an Array search retained and
// released every element around one compare). The pairs that must STAY: a
// call between them (it may drop the last other reference), and a store.
// Each case's answer and the object counts at the end check that nothing was
// freed early or leaked.

#import "Foundation.xc"
#import "Stdio.xc"

class Box
    {
    u32 v;
    }

u32 gLive = 0;
Array* gHold = 0;

bool hasVal(Array* a, Object* v)
    {
    for (u32 i = 0; i < a.count(); i = i + 1)
        if (a.get(i) == v) return true;
    return false;
    }

// The element is read after a call that empties the array holding it: the
// local's retain must keep it alive across the call.
u32 readAfterDrop(Array* a)
    {
    Box* b = (Box*)a.get(0);
    a.removeAll();
    return b.v;
    }

u32 sumAll(Array* a)
    {
    u32 s = 0;
    for (u32 i = 0; i < a.count(); i = i + 1)
        {
        Box* b = (Box*)a.get(i);
        s = s + b.v;
        }
    return s;
    }

void main(void)
    {
    Array* a = new Array();
    for (u32 i = 0; i < 50; i = i + 1)
        {
        Box* b = new Box();
        b.v = i * 3;
        a.add((Object*)b);
        }
    Object* last = a.get(49);
    Box* other = new Box();
    u32 hits = 0;
    for (u32 r = 0; r < 1000; r = r + 1)
        {
        if (hasVal(a, last)) hits = hits + 1;
        if (hasVal(a, (Object*)other)) hits = hits + 100000;
        }
    u32 s = sumAll(a);
    Array* c = new Array();
    Box* k = new Box();
    k.v = 77;
    c.add((Object*)k);
    k = 0;
    u32 kept = readAfterDrop(c);
    Stdio.printf("%u %u %u %u\n", hits, s, kept, a.count());
    }
