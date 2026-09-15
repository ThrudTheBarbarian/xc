// test_binaryheap.xc — UXBinaryHeap: a min-heap priority queue.
#import <Stdio.xc>
#import "UXBinaryHeap.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

class Item : Object
    {
    i32 id;
    void init(void)
        {
        id = (i32)0;
        }
    } Item* mk(i32 id)
    {
    Item* it = new Item();
    it.id = id;
    return it;
    }

void main(void)
    {
    gFails = (i32)0;
    UXBinaryHeap* q = new UXBinaryHeap();
    check("empty", q.isEmpty() ? (i32)1 : (i32)0, (i32)1);

    // Insert out of order; the min must always surface.
    q.insert(mk((i32)50), (i32)50);
    q.insert(mk((i32)20), (i32)20);
    q.insert(mk((i32)80), (i32)80);
    q.insert(mk((i32)10), (i32)10);
    q.insert(mk((i32)30), (i32)30);
    check("count 5", q.count(), (i32)5);
    check("minimum is 10", ((Item* ?)q.minimum()).id, (i32)10);
    check("minimumPriority is 10", q.minimumPriority(), (i32)10);

    // Drain: must come out in ascending priority order.
    i32 order[8];
    i32 on = (i32)0;
    while (!q.isEmpty())
        { order[on] = ((Item* ?)q.removeMinimum()).id;
        on = on + (i32)1;
        }
    check("drained all 5", on, (i32)5);
    check("out[0]", order[(i32)0], (i32)10);
    check("out[1]", order[(i32)1], (i32)20);
    check("out[2]", order[(i32)2], (i32)30);
    check("out[3]", order[(i32)3], (i32)50);
    check("out[4]", order[(i32)4], (i32)80);
    check("empty after drain", q.isEmpty() ? (i32)1 : (i32)0, (i32)1);
    check("removeMinimum on empty is null", q.removeMinimum() == (Object*)0 ? (i32)1 : (i32)0, (i32)1);

    // Duplicates + interleaved insert/remove keep the invariant.
    q.insert(mk((i32)5), (i32)5);
    q.insert(mk((i32)5), (i32)5); // equal priorities
    q.insert(mk((i32)1), (i32)1);
    check("min is 1 among dups", q.minimumPriority(), (i32)1);
    q.removeMinimum(); // pop the 1
    check("next min is 5", q.minimumPriority(), (i32)5);
    q.insert(mk((i32)3), (i32)3);
    check("new smaller min surfaces", q.minimumPriority(), (i32)3);
    check("count now 3", q.count(), (i32)3);

    // Stress: insert 0..99 shuffled-ish, must drain sorted.
    q.removeAll();
    i32 seed = (i32)7;
    for (i32 k = (i32)0; k < (i32)100; k = k + (i32)1)
        {
        seed = (seed * (i32)1103515245 + (i32)12345) & (i32)2147483647; // LCG, deterministic
        q.insert(mk(k), seed % (i32)1000);
        }
    i32 prev = (i32)-1;
    i32 sortedOK = (i32)1;
    i32 drained = (i32)0;
    while (!q.isEmpty())
        {
        i32 p = q.minimumPriority();
        q.removeMinimum();
        if (p < prev)
            {
            sortedOK = (i32)0;
            }
        prev = p;
        drained = drained + (i32)1;
        }
    check("stress drained 100", drained, (i32)100);
    check("stress drained in non-decreasing order", sortedOK, (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXBinaryHeap — min-heap order, drain, dups, interleave, 100-item stress.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
