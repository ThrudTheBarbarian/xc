//xtc-flags: target=arm64
// threads_nested_spawn.xc — threads that spawn threads: a binary tree three
// deep, each body spawning two and joining both, so 15 bodies run. On wasm32
// a thread's own instance once could not spawn at all (Thread.spawn there
// handed back a dead handle and this printed 1), and in a browser a Worker
// created by a blocked thread never starts: the loader's spawn queue covers
// both.
#import "Stdio.xc"
#import "Thread.xc"
#import "Atomic.xc"
class Work : Object
    {
    Atomic* count;
    u32 depth;
    void run(void)
        {
        count.add((i32)1);
        if (depth > (u32)0)
            {
            Work* a = new Work();
            a.count = count;
            a.depth = depth - (u32)1;
            Work* b = new Work();
            b.count = count;
            b.depth = depth - (u32)1;
            Thread* ta = Thread.spawn(&a.run);
            Thread* tb = Thread.spawn(&b.run);
            if (ta == (Thread*)0 || tb == (Thread*)0)
                Stdio.printf("spawn failed at depth %u\n", depth);
            if (ta != (Thread*)0) ta.join();
            if (tb != (Thread*)0) tb.join();
            }
        }
    }
i32 main(void)
{
    Work* w = new Work();
    w.count = new Atomic();
    w.depth = (u32)3;
    Thread* t = Thread.spawn(&w.run);
    t.join();
    Stdio.printf("ran %d\n", w.count.load());
    return 0;
}
