//xtc-flags: target=arm64
//xtc-na: wasm32 xt6502 m68k arm9 — RunLoop needs threads and a monotonic clock
// A block posted from another thread runs on the loop; a cancelled timer
// never fires; a repeating timer cancels itself after three ticks; stop()
// ends run().
#use Stdio
#import "RunLoop.xc"

u32 gTicks = (u32)0;
Timer* gEvery = (Timer*)0;

class Poster
    {
    u32 n;
    void run(void)
        {
        u32 k = n;
        RunLoop.main().post(block void(void) { Stdio.printf("posted %ld\n", k); });
        }
    }

i32 main(void)
    {
    RunLoop* loop = RunLoop.main();
    Poster* p = new Poster();
    p.n = (u32)7;
    Thread* t = Thread.spawn(&p.run);
    t.join();
    Timer* never = loop.after((u32)50, block void(void) { Stdio.printf("cancelled timer fired\n"); });
    never.cancel();
    // The third tick schedules the end of the test. A fixed deadline (stop
    // after 200 ms) raced the ticks, and on a loaded machine it won: the
    // loop thread got too little time for three 20 ms ticks, and the run
    // printed "ticks 2". A one-shot timer set from the third tick still
    // tests `after` firing, and cannot overtake the ticks.
    gEvery = loop.every((u32)20, block void(void) {
        gTicks = gTicks + (u32)1;
        if (gTicks == (u32)3)
            {
            gEvery.cancel();
            RunLoop.main().after((u32)10, block void(void) {
                Stdio.printf("ticks %ld\n", gTicks);
                RunLoop.main().stop();
                });
            }
        });
    loop.run();
    Stdio.printf("stopped\n");
    return 0;
    }
