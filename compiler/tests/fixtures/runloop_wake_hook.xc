//xtc-flags: target=arm64
//xtc-na: wasm32 xt6502 m68k arm9 — RunLoop needs threads and a monotonic clock
// A loop whose thread waits somewhere else (a UI event loop) installs a wake
// hook: every post, from any thread, calls it, and the owner then drains the
// queue with runPending(). Here a worker posts five progress updates; the
// hook counts the wakes, and the main thread runs the updates in order. A
// timer firing wakes the hook too, and a removed hook is not called.
#use Stdio
#import "RunLoop.xc"

Mutex* gLock = (Mutex*)0;
u32 gWakes = (u32)0;
u32 gLast = (u32)0;
bool gInOrder = true;

class Worker
    {
    void run(void)
        {
        for (u32 i = (u32)1; i <= (u32)5; i = i + (u32)1)
            {
            u32 k = i;
            RunLoop.main().post(block void(void) {
                if (k != gLast + (u32)1)
                    gInOrder = false;
                gLast = k;
                });
            }
        }
    }

u32 wakes(void)
    {
    gLock.lock();
    u32 n = gWakes;
    gLock.unlock();
    return n;
    }

i32 main(void)
    {
    gLock = new Mutex();
    RunLoop* loop = RunLoop.main();
    loop.setWakeHook(block void(void) {
        gLock.lock();
        gWakes = gWakes + (u32)1;
        gLock.unlock();
        }, true);
    Worker* w = new Worker();
    Thread* t = Thread.spawn(&w.run);
    t.join();
    Stdio.printf("wakes %ld\n", wakes());
    u32 ran = loop.runPending();
    Stdio.printf("ran %ld, last %ld, in order %s\n", ran, gLast, gInOrder ? "yes" : "no");
    loop.after((u32)10, block void(void) { gLast = (u32)99; });
    while (wakes() < (u32)6)
        Thread.sleepMs((u32)2);
    loop.runPending();
    Stdio.printf("timer woke the hook, last %ld\n", gLast);
    loop.setWakeHook(block void(void) { }, false);
    loop.post(block void(void) { });
    Stdio.printf("wakes after removal %ld\n", wakes());
    return 0;
    }
