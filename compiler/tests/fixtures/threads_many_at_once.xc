//xtc-flags: target=arm64
// threads_many_at_once.xc — 40 threads that must all be running at the same
// time: each waits until all 40 have started. On wasm32 in a browser this
// needs more workers than the starting pool (4 to 16), which the page adds as
// runs wait in the loader's spawn queue; a fixed pool waits forever here.
#import "Stdio.xc"
#import "Thread.xc"
#import "Atomic.xc"
class Waiter : Object
    {
    Atomic* started;
    void run(void)
        {
        started.add((i32)1);
        while (started.load() < (i32)40)
            Thread.sleepMs((u32)1);
        }
    }
i32 main(void)
{
    Atomic* started = new Atomic();
    Array* ts = new Array();
    // A bound method does not keep its receiver alive: the waiters are held
    // here until every thread has been joined.
    Array* ws = new Array();
    for (u32 i = (u32)0; i < (u32)40; i = i + (u32)1) {
        Waiter* w = new Waiter();
        w.started = started;
        ws.add((Object*)w);
        ts.add((Object*)Thread.spawn(&w.run));
    }
    for (u32 i = (u32)0; i < ts.count(); i = i + (u32)1)
        ((Thread*)ts.get(i)).join();
    Stdio.printf("all %d ran together\n", started.load());
    return 0;
}
