// Thread.setPriority: a worker lowers its own priority, first thing in its
// body, and still runs to the end. Lowering is allowed everywhere it means
// something (raising again may need privileges on Linux, so it is not tested).
//xtc-na: xt6502 m68k wasm32 arm9 — no threads with priorities
#import "Stdio.xc"
#import "Thread.xc"
class Worker : Object
    {
    bool lowered;
    u32 sum;
    void run(void)
        {
        lowered = Thread.setPriority(Thread.utility());
        for (u32 i = (u32)0; i < (u32)1000; i = i + (u32)1)
            sum = sum + i;
        }
    }
i32 main(void)
    {
    Worker* w = new Worker();
    Thread* t = Thread.spawn(&w.run);
    t.join();
    Stdio.printf("lowered %d, sum %u, out of range %d\n", (i32)w.lowered, w.sum,
                 (i32)Thread.setPriority((i32)7));
    return 0;
    }
