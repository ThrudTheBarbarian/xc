//xtc-na: xt6502 — Progress is not available on xt6502
// foundation_progress.xc — Progress: own units, children in their own
// measure, nesting, clamping, indeterminate totals and cancellation.
#import "Foundation.xc"
#import "Progress.xc"

void show(u8* what, Progress* p)
    {
    Stdio.printf("%-30s %u/1000 finished=%d indeterminate=%d\n", what, p.fractionPerMille(),
                 (i32)(p.isFinished() ? 1 : 0), (i32)(p.isIndeterminate() ? 1 : 0));
    }

i32 main(void)
    {
    Progress* whole = Progress.withTotal((i64)10);
    show("start", whole);
    Progress* files = whole.makeChild((i64)200, (i64)6);
    files.incrementBy((i64)100);
    show("child half of 6 units", whole);
    whole.incrementBy((i64)2);
    show("plus 2 own units", whole);
    Progress* inner = files.makeChild((i64)4, (i64)100);
    inner.setCompletedUnitCount((i64)4);
    show("grandchild finishes", whole);
    whole.incrementBy((i64)2);
    show("all done", whole);
    whole.incrementBy((i64)5);
    show("overshoot is clamped", whole);

    Progress* unknown = new Progress();
    show("no total", unknown);
    unknown.setTotalUnitCount((i64)3);
    unknown.incrementBy((i64)1);
    show("total known later", unknown);

    Progress* job = Progress.withTotal((i64)2);
    Progress* a = job.makeChild((i64)1, (i64)1);
    job.cancel();
    Progress* late = job.makeChild((i64)1, (i64)1);
    Stdio.printf("cancelled: job=%d child=%d added later=%d\n", (i32)(job.isCancelled() ? 1 : 0),
                 (i32)(a.isCancelled() ? 1 : 0), (i32)(late.isCancelled() ? 1 : 0));
    return (i32)0;
    }
