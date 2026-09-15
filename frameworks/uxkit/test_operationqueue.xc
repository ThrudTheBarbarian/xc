// test_operationqueue.xc — UXOperationQueue: dependency-ordered execution, cancel, deadlock.
#import <Stdio.xc>
#import "UXOperationQueue.xc"

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

// Records the order in which operations run, keyed by tag, into a global log.
i32 gLog[16];
i32 gLogN;
class Worker : Object
    {
    void init(void)
        {
        }
    void run(UXOperation* op)
        {
        gLog[gLogN] = op.tag;
        gLogN = gLogN + (i32)1;
        }
    }
    // index of tag in the run log, or -1
    i32 posOf(i32 tag)
    {
    for (i32 i = (i32)0; i < gLogN; i = i + (i32)1)
        {
        if (gLog[i] == tag)
            {
            return i;
            }
        }
    return (i32)-1;
    }

void main(void)
    {
    gFails = (i32)0;
    gLogN = (i32)0;
    Worker* w = new Worker();

    // A ; B->A ; C->A ; D->B,C   (D must be last, A must be first)
    UXOperation* a = UXOperation.make((i32)1, &w.run);
    UXOperation* b = UXOperation.make((i32)2, &w.run);
    UXOperation* c = UXOperation.make((i32)3, &w.run);
    UXOperation* d = UXOperation.make((i32)4, &w.run);
    b.addDependency(a);
    c.addDependency(a);
    d.addDependency(b);
    d.addDependency(c);

    UXOperationQueue* q = new UXOperationQueue();
    // add in a deliberately awkward order to prove the scheduler, not insertion order, wins
    q.addOperation(d);
    q.addOperation(b);
    q.addOperation(c);
    q.addOperation(a);
    q.run();

    check("all four ran", q.ranCount(), (i32)4);
    check("all finished", q.allFinished() ? (i32)1 : (i32)0, (i32)1);
    check("not deadlocked", q.isDeadlocked() ? (i32)1 : (i32)0, (i32)0);
    check("A before B", posOf((i32)1) < posOf((i32)2) ? (i32)1 : (i32)0, (i32)1);
    check("A before C", posOf((i32)1) < posOf((i32)3) ? (i32)1 : (i32)0, (i32)1);
    check("B before D", posOf((i32)2) < posOf((i32)4) ? (i32)1 : (i32)0, (i32)1);
    check("C before D", posOf((i32)3) < posOf((i32)4) ? (i32)1 : (i32)0, (i32)1);
    check("A ran first", gLog[(i32)0], (i32)1);
    check("D ran last", gLog[gLogN - (i32)1], (i32)4);

    // cancellation: cancel B; it should not run, but D (dep on B,C) still proceeds
    gLogN = (i32)0;
    UXOperation* a2 = UXOperation.make((i32)1, &w.run);
    UXOperation* b2 = UXOperation.make((i32)2, &w.run);
    UXOperation* c2 = UXOperation.make((i32)3, &w.run);
    UXOperation* d2 = UXOperation.make((i32)4, &w.run);
    b2.addDependency(a2);
    d2.addDependency(b2);
    d2.addDependency(c2);
    b2.cancel();
    UXOperationQueue* q2 = new UXOperationQueue();
    q2.addOperation(a2);
    q2.addOperation(b2);
    q2.addOperation(c2);
    q2.addOperation(d2);
    q2.run();
    check("cancelled op did not run (3 ran)", q2.ranCount(), (i32)3);
    check("B is not in the run log", posOf((i32)2), (i32)-1);
    check("cancelled op still counts as finished", b2.isFinished() ? (i32)1 : (i32)0, (i32)1);
    check("D still ran after cancel", posOf((i32)4) >= (i32)0 ? (i32)1 : (i32)0, (i32)1);
    check("q2 all finished", q2.allFinished() ? (i32)1 : (i32)0, (i32)1);

    // deadlock: a cycle X<->Y makes no progress
    gLogN = (i32)0;
    UXOperation* x = UXOperation.make((i32)10, &w.run);
    UXOperation* y = UXOperation.make((i32)11, &w.run);
    x.addDependency(y);
    y.addDependency(x);
    UXOperationQueue* q3 = new UXOperationQueue();
    q3.addOperation(x);
    q3.addOperation(y);
    q3.run();
    check("cycle detected as deadlock", q3.isDeadlocked() ? (i32)1 : (i32)0, (i32)1);
    check("nothing ran in the cycle", q3.ranCount(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXOperationQueue — dependency ordering, cancellation, deadlock detection.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
