//xtc-flags: target=arm64
// threads_first_worker_id.xc — the first spawned thread's id is not the
// main thread's. On arm9 the kernel numbers the main thread 0 and spawned
// threads from 1, and the main thread's id was once mapped to 1, which gave
// it the first worker's id.
#import "Stdio.xc"
#import "Thread.xc"

u32 gFirst = 0;
u32 gSecond = 0;

void first(void) { gFirst = Thread.currentId(); }
void second(void) { gSecond = Thread.currentId(); }

i32 main(void)
    {
    u32 mainId = Thread.currentId();
    Thread* a = Thread.spawn(&first);
    a.join();
    Thread* b = Thread.spawn(&second);
    b.join();
    Stdio.printf("main nonzero %s\n", mainId != 0 ? "yes" : "no");
    Stdio.printf("first differs from main %s\n", gFirst != mainId ? "yes" : "no");
    Stdio.printf("second differs from main %s\n", gSecond != mainId ? "yes" : "no");
    return 0;
    }
