// UXOperationQueue.xc — operations with dependencies, run in a correct order (NSOperationQueue shape).
//
// An operation carries a block of work and a list of DEPENDENCIES that must finish before it may run.
// The queue resolves that partial order and runs each operation once its dependencies are done.  This
// layer is the SCHEDULER — deterministic and unit-testable — and runs the operations serially in a
// valid topological order; a threaded backend (once XTOS has threads) reuses exactly this readiness
// logic to run independent operations concurrently.  Cancelled operations are skipped but still count
// as finished so their dependents proceed.
#import "Array.xc"

#define UXOP_PENDING 0
#define UXOP_FINISHED 1

class UXOperation
    {
    callback block void(UXOperation* op); // the work; never owns its target (the app keeps it alive)
    Array<UXOperation>* deps;
    i32 state;
    i32 tag; // app/test identity
    bool cancelled;
    void init(void)
        {
        block = (callback void(UXOperation * op))0;
        deps = new Array();
        state = (i32)UXOP_PENDING;
        tag = (i32)0;
        cancelled = false;
        }

    static UXOperation* make(i32 tag, callback block void(UXOperation* op))
        {
        UXOperation* o = new UXOperation();
        o.tag = tag;
        o.block = block;
        return o;
        }
    void addDependency(UXOperation* o)
        {
        if (o != (UXOperation*)0)
            {
            deps.add(o);
            }
        }
    void cancel(void)
        {
        cancelled = true;
        }
    bool isFinished(void)
        {
        return state == (i32)UXOP_FINISHED;
        }
    bool isCancelled(void)
        {
        return cancelled;
        }
    // ready when every dependency has finished.
    bool isReady(void)
        {
        if (state == (i32)UXOP_FINISHED)
            {
            return false;
            }
        for (u16 i = (u16)0; i < deps.count(); i = i + (u16)1)
            {
            if (!((UXOperation* ?)deps.get(i)).isFinished())
                {
                return false;
                }
            }
        return true;
        }
    // run the work (unless cancelled), then mark finished.
    void execute(void)
        {
        if (!cancelled)
            {
            callback b void(UXOperation * op) = block;
            if (b != (callback void(UXOperation * op))0)
                {
                b(self);
                }
            }
        state = (i32)UXOP_FINISHED;
        }
    }

    class UXOperationQueue
    {
    Array<UXOperation>* ops;
    Array<UXOperation>* order; // tags in execution order (cancelled ones excluded) — for tests/inspection
    bool deadlocked;           // true if a dependency cycle stopped progress
    void init(void)
        {
        ops = new Array();
        order = new Array();
        deadlocked = false;
        }

    void addOperation(UXOperation* o)
        {
        ops.add(o);
        }
    i32 count(void)
        {
        return (i32)ops.count();
        }
    i32 ranCount(void)
        {
        return (i32)order.count();
        }
    i32 ranTagAt(i32 i)
        { return ((UXOperation* ?)order.get((u16)i)).tag;
        }

    // Run every operation once its dependencies are satisfied, recording the order.  Stops early and
    // sets deadlocked if a round makes no progress while operations remain (a dependency cycle).
    void run(void)
        {
        deadlocked = false;
        bool progress = true;
        while (progress)
            {
            progress = false;
            bool remaining = false;
            for (u16 i = (u16)0; i < ops.count(); i = i + (u16)1)
                {
                UXOperation* o = (UXOperation* ?)ops.get(i);
                if (o.isFinished())
                    {
                    continue;
                    }
                remaining = true;
                if (o.isReady())
                    {
                    bool wasCancelled = o.isCancelled();
                    o.execute();
                    // record only work that actually ran
                    if (!wasCancelled)
                        {
                        order.add(o);
                        }
                    progress = true;
                    }
                }
            if (!progress && remaining)
                {
                deadlocked = true;
                }
            }
        }
    bool isDeadlocked(void)
        {
        return deadlocked;
        }
    bool allFinished(void)
        {
        for (u16 i = (u16)0; i < ops.count(); i = i + (u16)1)
            {
            if (!((UXOperation* ?)ops.get(i)).isFinished())
                {
                return false;
                }
            }
        return true;
        }
    }
