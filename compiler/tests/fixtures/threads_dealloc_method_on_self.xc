//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// threads_dealloc_method_on_self.xc — a dealloc that calls a method on self,
// in a program that spawns a thread (bug 608).
//
// Spawning a thread turns on thread-safe ARC for the whole module, and the
// method retains self on entry and releases it on exit. While dealloc runs the
// runtime parks the count at 0x80000000, so a nested retain/release must not
// take it to zero. The arm64 atomic release decremented only the low 16 bits:
// 0x80000001 read as 1, the release called dealloc again from inside dealloc,
// and the program overflowed its stack. The plain (single-threaded) release was
// always 32-bit, which is why the same class survived without a thread.
#import "Stdio.xc"
#import "Thread.xc"

u32 gClosed = (u32)0;

// The bug needs the method to retain and release self, and the compiler emits
// that only when the method passes an ivar to a call it cannot see into. Any
// external C function does; WHICH one does not matter, and abs() is called for
// its shape, not its meaning. UXKit's sockets called close(), which msvcrt.dll
// exports only as _close, so on Windows the fixture failed to load (bug 609).
i32 abs(i32 v);

void closeFd(i32 fd)
    {
    if (abs(fd) > 1)
        gClosed = gClosed + (u32)100;
    gClosed = gClosed + (u32)1;
    }

class Sock
    {
    i64 fd;
    bool open;
    void init(void)
        {
        fd = (i64)-1;
        open = true;
        }
    void close(void)
        {
        if (!open)
            return;
        closeFd((i32)fd);
        open = false;
        }
    void dealloc(void)
        {
        self.close();
        }
    }

class Idle
    {
    void run(void)
        {
        }
    }

void main(void)
    {
    Idle* w = new Idle();
    Thread* t = Thread.spawn(&w.run);
    t.join();

    Sock* a = new Sock();
    a = (Sock*)0;
    Sock* b = new Sock();
    b.close();
    b = (Sock*)0;
    Stdio.printf("closed=%u\n", gClosed);
    }
